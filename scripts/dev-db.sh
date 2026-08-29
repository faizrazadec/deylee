#!/bin/bash
# Builds the development database: a throwaway Postgres in a container carrying
# the same schema as production.
#
#     ./scripts/dev-db.sh          # create (or recreate) it from scratch
#
# Development deliberately does not share production's database. The free plan
# allows two Supabase projects and both are already in use, but a local Postgres
# is the better answer regardless: it is instant, offline, disposable, and a
# mistake made against it cannot reach a customer's hours.
set -euo pipefail
cd "$(dirname "$0")/.."

NETWORK=deylee-v6
NAME=deylee-dev-db
PORT=5433
DEV="postgresql://postgres:devpassword@127.0.0.1:$PORT/postgres"

docker network inspect "$NETWORK" >/dev/null 2>&1 \
  || docker network create --ipv6 --subnet fd00:de00::/64 "$NETWORK" >/dev/null

echo "starting $NAME"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --network "$NETWORK" --restart unless-stopped \
  -e POSTGRES_PASSWORD=devpassword -e POSTGRES_DB=postgres \
  -p "$PORT:5432" postgres:17-alpine >/dev/null

until docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 0.5; done

# Supabase's platform supplies these; a stock Postgres does not. Without them the
# first migration fails halfway — its foreign keys name auth.users, and its
# policies call auth.uid(), neither of which exists here. Later migrations replace
# both, so the end state is identical either way; this only makes the path there
# clean rather than a confusing partial failure.
echo "adding the pieces supabase would have provided"
psql "$DEV" -v ON_ERROR_STOP=1 -q <<'SQL'
create schema if not exists extensions;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid());
-- Returns null, exactly as it would for an unauthenticated request. Migration 2
-- drops every policy that calls this.
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;

-- Supabase's built-in roles. Migration 1 grants its policies `to authenticated`,
-- and a GRANT naming a role that does not exist is an error, not a no-op.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end
$$;
SQL

echo "applying migrations"
for f in supabase/migrations/*.sql; do
  psql "$DEV" -v ON_ERROR_STOP=1 -q -f "$f" >/dev/null
  echo "  $(basename "$f")"
done

# The restricted login the API uses, mirroring production. Its password is not a
# secret worth protecting: this database holds nothing real and is not reachable
# from outside this machine.
echo "creating the api login"
psql "$DEV" -v ON_ERROR_STOP=1 -q <<'SQL'
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'deylee_api_user') then
    create role deylee_api_user login password 'devpassword';
  end if;
end
$$;
grant deylee_api to deylee_api_user;
SQL

psql "$DEV" -tA <<'SQL'
select 'tables:    ' || string_agg(tablename, ', ' order by tablename) from pg_tables where schemaname='public';
select 'functions: ' || count(*) || ' auth_*' from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname like 'auth\_%';
select 'rls on:    ' || count(*) || ' tables' from pg_tables where schemaname='public' and rowsecurity;
SQL

echo
echo "DEYLEE_DB_URL for .env.dev:"
echo "  postgresql://deylee_api_user:devpassword@$NAME:5432/postgres"
echo "(the container name, because the API reaches it across the docker network)"
echo
echo "for the suite:"
echo "  DEYLEE_TEST_DB_URL='postgresql://deylee_api_user:devpassword@127.0.0.1:$PORT/postgres' \\"
echo "  DEYLEE_TEST_DB_OWNER_URL='$DEV' \\"
echo "    ./scripts/test-server.sh"
echo "(the first must be the restricted login — as the owner every tenancy test passes"
echo " while proving nothing. The second only reads the append-only tables the"
echo " restricted role is deliberately not granted.)"

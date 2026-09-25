#!/bin/bash
# Builds the development database: a throwaway Postgres in a container carrying
# the same schema as production.
#
#     ./scripts/dev-db.sh          # create (or recreate) it from scratch
#
# Development deliberately does not share production's database: a local Postgres
# is instant, offline, disposable, and a mistake made against it cannot reach a
# customer's hours. Production is the same image, built by the same migrate.sh.
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

echo "applying migrations"
PSQL="docker exec -i $NAME psql -U postgres -d postgres" ./scripts/migrate.sh

# The restricted login the API uses, mirroring production. Its password is not a
# secret worth protecting: this database holds nothing real and is not reachable
# from outside this machine.
echo "creating the api login"
docker exec -i "$NAME" psql -U postgres -X -v ON_ERROR_STOP=1 -q <<'SQL'
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'deylee_api_user') then
    create role deylee_api_user login password 'devpassword';
  end if;
end
$$;
grant deylee_api to deylee_api_user;
SQL

docker exec -i "$NAME" psql -U postgres -X -tA <<'SQL'
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

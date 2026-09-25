#!/bin/bash
# Applies server/migrations/ in order: each file once, each in its own transaction, and
# records it in deylee_migrations.applied so a second run applies nothing.
#
#     ./scripts/migrate.sh                                          # the dev database
#     PSQL="docker exec -i deylee-db psql -U postgres -d postgres" \
#       ./server/scripts/migrate.sh                                 # production
#
# PSQL is the whole psql invocation, connection included. SQL goes in on stdin, so it
# works just as well through `docker exec` into a container with no published port.
#
# Forwards only. A file already recorded is never run again, which is why a migration
# that shipped is never edited: the change would reach a fresh database and nothing else.
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL=${PSQL:-docker exec -i deylee-dev-db psql -U postgres -d postgres}
run() { $PSQL -X -q -v ON_ERROR_STOP=1 "$@"; }

run <<'SQL'
create schema if not exists deylee_migrations;
create table if not exists deylee_migrations.applied (
  version    text        primary key,
  applied_at timestamptz not null default now()
);
SQL

applied=$(run -tA -c "select version from deylee_migrations.applied")

# A fresh database. The first migration was written against Supabase, which supplies
# these: its foreign keys name auth.users, its policies call auth.uid() and are granted
# `to authenticated`. Later migrations replace all of them, so the end state is the same
# either way; this only lets the history replay on a stock Postgres.
if [ -z "$applied" ]; then
  echo "fresh database: adding the pieces the first migration expects"
  run <<'SQL'
create schema if not exists extensions;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid());
-- Null, as for an unauthenticated request. Migration 2 drops every policy that calls it.
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
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
fi

count=0
for f in migrations/*.sql; do
  version=$(basename "$f" .sql)
  grep -qxF "$version" <<<"$applied" && continue
  {
    echo "begin;"
    cat "$f"
    echo
    echo "insert into deylee_migrations.applied (version) values ('$version');"
    echo "commit;"
  } | run >/dev/null
  echo "  applied $version"
  count=$((count + 1))
done
echo "$count migration(s) applied"

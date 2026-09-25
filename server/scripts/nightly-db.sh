#!/bin/bash
# The database's nightly job, run by cron on the host that runs compose:
#
#     17 3 * * *  /opt/deylee/server/scripts/nightly-db.sh /srv/deylee-backups
#
# 1. Sweeps expired refresh tokens. Supabase ran this through pg_cron; a stock Postgres
#    has no scheduler, so it lives here (see the sweep_refresh_tokens migration).
# 2. Dumps the whole database, custom format, keeping the newest KEEP (default 14).
#
# A dump on the same disk as the database survives a bad migration, not a dead disk.
# Copy the directory off the machine too.
#
# Restore into an empty `deylee-db`:
#     docker exec -i deylee-db psql -U postgres -d postgres < roles.sql
#     docker exec -i deylee-db pg_restore -U postgres -d postgres --clean --if-exists < FILE
set -euo pipefail
# Every customer's hours, and the roles' password hashes: owner-only.
umask 077

DIR=${1:?usage: nightly-db.sh <backup-directory>}
KEEP=${KEEP:-14}
CONTAINER=${CONTAINER:-deylee-db}

docker exec "$CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 \
  -c "select public.auth_sweep_expired_refresh_tokens()" >/dev/null

mkdir -p "$DIR"
out="$DIR/deylee-$(date -u +%Y%m%dT%H%M%SZ).dump"
# Written aside and renamed, so a dump cut short never looks like a good one.
docker exec "$CONTAINER" pg_dump -U postgres -d postgres -Fc >"$out.partial"
mv "$out.partial" "$out"
# Roles are cluster-wide, so pg_dump leaves them out, and the grants in the dump name
# them. Restore this first.
docker exec "$CONTAINER" pg_dumpall -U postgres --roles-only >"$DIR/roles.sql"

ls -1t "$DIR"/deylee-*.dump | tail -n +$((KEEP + 1)) | while read -r old; do rm -f -- "$old"; done
echo "backed up to $out"

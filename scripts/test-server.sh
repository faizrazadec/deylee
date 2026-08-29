#!/bin/bash
# The sync API's suite. Re-enters server/ — its own package, separate from the app —
# so this runs from anywhere in the repository.
#
# The tenancy suites are skipped unless a database is pointed at them, because
# row-level security is the thing under test and a mock would only prove the mock.
# `./scripts/dev-db.sh` builds one; then:
#
#   DEYLEE_TEST_DB_URL='postgresql://deylee_api_user:devpassword@127.0.0.1:5433/postgres' \
#     ./scripts/test-server.sh
#
# It must be the restricted login. As `postgres` every one of them passes while
# proving nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
exec uv run pytest "$@"

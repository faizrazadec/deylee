#!/bin/bash
# Commits the actual cheats against a running API and proves each one leaves ink —
# or is refused at the door. Then removes everything it created and proves that too.
#
#   API=http://127.0.0.1:8081 ENV_FILE=.env.dev ./scripts/smoke-integrity.sh   # dev
#   API=https://api.faizraza.me ./scripts/smoke-integrity.sh                    # prod
#
# The cheats, in the order a real cheater discovers them:
#   1. an honest day syncs                      -> no ink
#   2. the open segment closes                  -> still no ink (the timer's own act)
#   3. a closed segment is edited after sync    -> 'edited'
#   4. a synced segment is deleted              -> 'deleted'
#   5. hours are filed days after the fact      -> 'late-claim'
#   6. a seventeen-hour segment                 -> refused
#   7. a segment ending in the future           -> refused
#
# The last check is the one that matters most: the probe's bearer token cannot
# read, change or remove the ink, because the API grants no verb for it.
set -uo pipefail
cd "$(dirname "$0")/.."

API=${API:-http://127.0.0.1:8080}
ENV_FILE=${ENV_FILE:-.env}
DBURL=$(grep '^DEYLEE_DB_OWNER_URL=' "$ENV_FILE" | cut -d= -f2-)
EMAIL="integrity-probe@deylee-smoke.invalid"
PASS="a-good-password"
FAILURES=0

if [ -z "$DBURL" ]; then echo "DEYLEE_DB_OWNER_URL is not set in $ENV_FILE" >&2; exit 1; fi
if ! curl -s --max-time 5 "$API/health" >/dev/null; then
  echo "The API is not answering at $API" >&2; exit 1
fi

purge() { psql "$DBURL?connect_timeout=15" -tAc \
  "delete from public.app_users where email like '%@deylee-smoke.invalid';
   delete from public.pending_signups where email like '%@deylee-smoke.invalid'" >/dev/null 2>&1; }

cleanup() {
  purge
  echo
  echo "cleanup"
  psql "$DBURL?connect_timeout=15" -tA <<'SQL' | sed 's/^/  /'
select 'probe rows left: ' || count(*) from public.app_users
 where email like '%@deylee-smoke.invalid';
select 'probe ink left: ' || count(*) from public.audit_marks m
 where not exists (select 1 from public.app_users u where u.id = m.user_id);
SQL
  echo
  [ "$FAILURES" -eq 0 ] && echo "all checks passed" || echo "$FAILURES check(s) FAILED"
  exit "$FAILURES"
}
trap cleanup EXIT
purge

ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
post() { curl -s --max-time 30 -X POST "$API$1" -H 'Content-Type: application/json' \
           ${TOKEN:+-H "Authorization: Bearer $TOKEN"} --data-raw "$2"; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)" 2>/dev/null; }

# Milliseconds, from the machine running the test. Fine for building payloads;
# every judgment about time is the server's.
now=$(python3 -c "import time;print(int(time.time()*1000))")
HOUR=3600000

echo "create the probe account"
OTP="424242"
psql "$DBURL?connect_timeout=15" -tAc \
  "select public.auth_request_signup_code('$EMAIL','$PASS','Probe','UTC','$OTP',600,0)" >/dev/null
OUT=$(post /v1/auth/signup/verify "{\"email\":\"$EMAIL\",\"code\":\"$OTP\"}")
TOKEN=$(echo "$OUT" | field "['accessToken']")
USERID=$(echo "$OUT" | field "['user']['id']")
[ -n "$TOKEN" ] && ok "signed in" || { bad "no session: $OUT"; exit 1; }

marks() { psql "$DBURL?connect_timeout=15" -tAc \
  "select count(*) from public.audit_marks where user_id = '$USERID'${1:+ and kind = '$1'}"; }
sync() { post /v1/sync "{\"protocolVersion\":1,\"cursor\":0,\"changes\":$1}"; }
seg()  { # id, startedAt, endedAt-or-null, updatedAt
  echo "{\"table\":\"segments\",\"op\":\"upsert\",\"row\":{\"id\":\"$1\",\"dayDate\":\"2026-08-08\",\"type\":\"work\",\"startedAt\":$2,\"endedAt\":$3,\"updatedAt\":$4,\"createdAt\":$4}}"
}
uuid() { python3 -c "import uuid;print(uuid.uuid4())"; }

echo "an honest day leaves no ink"
S1=$(uuid)
OUT=$(sync "[$(seg "$S1" $((now - 3 * HOUR)) $((now - 2 * HOUR)) $((now - 2 * HOUR)))]")
[ "$(echo "$OUT" | field "['results'][0]['status']")" = "applied" ] \
  && ok "closed segment accepted" || bad "honest segment rejected: $OUT"
[ "$(marks)" = "0" ] && ok "no ink" || bad "honest sync left ink"

echo "closing the open segment is not an edit"
S2=$(uuid)
sync "[$(seg "$S2" $((now - HOUR)) null $((now - HOUR)))]" >/dev/null
sync "[$(seg "$S2" $((now - HOUR)) $((now - 60000)) $((now - 60000)))]" >/dev/null
[ "$(marks)" = "0" ] && ok "still no ink" || bad "the timer's own close was marked"

echo "editing a synced segment leaves ink"
OUT=$(sync "[$(seg "$S1" $((now - 6 * HOUR)) $((now - 1 * HOUR)) $now)]")
[ "$(echo "$OUT" | field "['results'][0]['status']")" = "applied" ] \
  && ok "the edit is accepted — walls are not the design" || bad "edit rejected: $OUT"
[ "$(marks edited)" = "1" ] && ok "kind 'edited', with before and after" \
  || bad "no 'edited' ink (have: $(marks edited))"

echo "deleting a synced segment leaves ink"
sync "[{\"table\":\"segments\",\"op\":\"delete\",\"row\":{\"id\":\"$S2\",\"updatedAt\":$now}}]" >/dev/null
[ "$(marks deleted)" = "1" ] && ok "kind 'deleted'" || bad "no 'deleted' ink"

echo "hours filed three days late leave ink"
S3=$(uuid)
sync "[$(seg "$S3" $((now - 75 * HOUR)) $((now - 73 * HOUR)) $((now - 73 * HOUR)))]" >/dev/null
[ "$(marks late-claim)" = "1" ] && ok "kind 'late-claim'" || bad "no 'late-claim' ink"

echo "the absurd is refused at the door"
S4=$(uuid)
OUT=$(sync "[$(seg "$S4" $((now - 18 * HOUR)) $((now - 1 * HOUR)) $now)]")
[ "$(echo "$OUT" | field "['results'][0]['status']")" = "rejected" ] \
  && ok "seventeen hours refused" || bad "a 17-hour segment was accepted: $OUT"
S5=$(uuid)
OUT=$(sync "[$(seg "$S5" $((now - HOUR)) $((now + 2 * HOUR)) $now)]")
[ "$(echo "$OUT" | field "['results'][0]['status']")" = "rejected" ] \
  && ok "the future refused" || bad "a future segment was accepted: $OUT"

echo "the token has no verb for the ink"
# The probe's own bearer token, aimed straight at the audit table through the
# only door there is. Every sentence the API understands must leave it intact.
OUT=$(sync "[{\"table\":\"audit_marks\",\"op\":\"delete\",\"row\":{\"id\":\"$S1\",\"updatedAt\":$now}}]")
[ "$(echo "$OUT" | field "['results'][0]['status']")" = "rejected" ] \
  && ok "audit_marks is not a table the protocol knows" \
  || bad "the sync route accepted a write against the ink: $OUT"
TOTAL=$(marks)
[ "$TOTAL" = "3" ] && ok "the ink stands at 3, untouched" \
  || bad "expected 3 marks, found $TOTAL"

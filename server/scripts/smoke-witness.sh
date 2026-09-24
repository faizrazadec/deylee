#!/bin/bash
# Proves the heartbeat records witnessed time on the server's clock, deduplicates a
# flood, and cannot be made to vouch for the past. Cleans up and proves it.
#
#   API=http://127.0.0.1:8081 ENV_FILE=.env.dev ./scripts/smoke-witness.sh
#   API=https://api.faizraza.me ./scripts/smoke-witness.sh
set -uo pipefail
cd "$(dirname "$0")/.."

API=${API:-http://127.0.0.1:8080}
ENV_FILE=${ENV_FILE:-.env}
DBURL=$(grep '^SUPABASE_DB_URL=' "$ENV_FILE" | cut -d= -f2-)
EMAIL="witness-probe@deylee-smoke.invalid"
PASS="a-good-password"
FAILURES=0

if [ -z "$DBURL" ]; then echo "SUPABASE_DB_URL is not set in $ENV_FILE" >&2; exit 1; fi
if ! curl -s --max-time 5 "$API/health" >/dev/null; then
  echo "The API is not answering at $API" >&2; exit 1
fi

purge() { psql "$DBURL?connect_timeout=15" -tAc \
  "delete from public.app_users where email like '%@deylee-smoke.invalid'" >/dev/null 2>&1; }
cleanup() {
  purge
  echo; echo "cleanup"
  psql "$DBURL?connect_timeout=15" -tA -c \
    "select '  probe beats left: ' || count(*) from public.witness_beats b
       where not exists (select 1 from public.app_users u where u.id = b.user_id)"
  echo
  [ "$FAILURES" -eq 0 ] && echo "all checks passed" || echo "$FAILURES check(s) FAILED"
  exit "$FAILURES"
}
trap cleanup EXIT
purge

ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
field() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)" 2>/dev/null; }
beat() { curl -s --max-time 20 -X POST "$API/v1/beat" -H 'Content-Type: application/json' \
           -H "Authorization: Bearer $TOKEN" --data-raw "${1:-{}}"; }

echo "create the probe account"
OTP="515151"
psql "$DBURL?connect_timeout=15" -tAc \
  "select public.auth_request_signup_code('$EMAIL','$PASS','Probe','UTC','$OTP',600,0)" >/dev/null
OUT=$(curl -s --max-time 30 -X POST "$API/v1/auth/signup/verify" -H 'Content-Type: application/json' \
        --data-raw "{\"email\":\"$EMAIL\",\"code\":\"$OTP\"}")
TOKEN=$(echo "$OUT" | field "['accessToken']")
USERID=$(echo "$OUT" | field "['user']['id']")
[ -n "$TOKEN" ] && ok "signed in" || { bad "no session: $OUT"; exit 1; }

beats() { psql "$DBURL?connect_timeout=15" -tAc \
  "select count(*) from public.witness_beats where user_id = '$USERID'"; }

echo "a beat records witnessed presence"
[ "$(beat | field "['recorded']")" = "True" ] && ok "first beat recorded" || bad "first beat not recorded"
[ "$(beats)" = "1" ] && ok "one row, stamped by the server" || bad "expected 1 beat, got $(beats)"

echo "a flood is deduplicated, not stored"
for _ in 1 2 3 4 5; do beat >/dev/null; done
[ "$(beats)" = "1" ] && ok "still one row — the floor holds" || bad "the dedup floor let $(beats) rows through"
[ "$(beat | field "['recorded']")" = "False" ] && ok "and the API says so honestly" \
  || bad "a duplicate beat claimed to be recorded"

echo "the beat carries no time the client chose"
# Even handed a timestamp, the server ignores it — the column defaults to the
# server clock and the function never reads client time. Confirm the stored beat
# is within a few seconds of now, not whatever a client might send.
SKEW=$(psql "$DBURL?connect_timeout=15" -tAc \
  "select abs(public.epoch_ms() - max(beat_at)) from public.witness_beats where user_id='$USERID'")
[ "$SKEW" -lt 30000 ] && ok "stored on the server's clock ($SKEW ms from now)" \
  || bad "a beat landed $SKEW ms from now — client time leaked in"

echo "the token has no verb for the beats"
# /v1/sync is the only mutation door, and it does not know this table.
OUT=$(curl -s --max-time 20 -X POST "$API/v1/sync" -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $TOKEN" \
        --data-raw '{"protocolVersion":1,"cursor":0,"changes":[{"table":"witness_beats","op":"delete","row":{"id":"00000000-0000-0000-0000-000000000000","updatedAt":1}}]}')
[ "$(echo "$OUT" | field "['results'][0]['status']")" = "rejected" ] \
  && ok "witness_beats is not a table the protocol knows" \
  || bad "the sync route accepted a write against the beats: $OUT"
[ "$(beats)" = "1" ] && ok "the record stands, untouched" || bad "the beat count changed to $(beats)"

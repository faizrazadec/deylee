#!/bin/bash
# Exercises the password sign-up, sign-in, refresh and account-linking flows
# against a running API, then removes everything it created and proves it.
#
#   ./scripts/smoke-auth.sh                     # against http://127.0.0.1:8080
#   API=https://api.example.com ./scripts/smoke-auth.sh
#
# Requires the API to be running and .env to hold SUPABASE_DB_URL, which is used
# only to create the probe rows, exercise the Google linking function directly, and
# clean up afterwards.
#
# Every row it writes uses an @deylee-smoke.invalid address — a reserved TLD that
# can never belong to a real person — so a failed cleanup is still obvious and can
# never collide with a customer.
set -uo pipefail
cd "$(dirname "$0")/.."

API=${API:-http://127.0.0.1:8080}
# ENV_FILE selects which environment is under test, so the probe rows and the
# cleanup land in the same database the API is writing to. Pointing the HTTP
# calls at one and the SQL at another would report failures that are really just
# two different databases disagreeing.
ENV_FILE=${ENV_FILE:-.env}
DBURL=$(grep '^SUPABASE_DB_URL=' "$ENV_FILE" | cut -d= -f2-)
# Unique per run, and that is load-bearing rather than tidy. Sign-in is throttled per
# address — ten failed attempts in five minutes — and that counter lives in the API
# process's memory, so deleting the rows between runs does not reset it. With one fixed
# address, two runs inside five minutes spent the budget between them and the third
# failed on a legitimate sign-in that the throttle was right to refuse. The domain stays
# the same, so the cleanup below still matches everything this script writes.
RUN="$$-${RANDOM}"
EMAIL="probe-$RUN@deylee-smoke.invalid"
PASS="a-good-password"
FAILURES=0

if [ -z "$DBURL" ]; then echo "SUPABASE_DB_URL is not set in .env" >&2; exit 1; fi
if ! curl -s --max-time 5 "$API/health" >/dev/null; then
  echo "The API is not answering at $API" >&2
  echo "Start it with: DEYLEE_ENV_FILE=\$PWD/server/.env uv run --project server python -m deylee_api" >&2
  exit 1
fi

# Both tables. A pending sign-up is keyed by address, so one left behind holds the
# probe address hostage and every later run fails on a stale row rather than a bug.
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
select 'pending rows left: ' || count(*) from public.pending_signups
 where email like '%@deylee-smoke.invalid';
SQL
  echo
  [ "$FAILURES" -eq 0 ] && echo "all checks passed" || echo "$FAILURES check(s) FAILED"
  exit "$FAILURES"
}
trap cleanup EXIT
purge

ok()   { echo "  ok    $1"; }
bad()  { echo "  FAIL  $1"; FAILURES=$((FAILURES + 1)); }
post() { curl -s --max-time 30 -X POST "$API$1" -H 'Content-Type: application/json' --data-raw "$2"; }
code() { curl -s -o /tmp/.deylee-smoke -w '%{http_code}' --max-time 30 -X POST "$API$1" \
           -H 'Content-Type: application/json' --data-raw "$2"; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)" 2>/dev/null; }
same()  { [ "$(echo "$1" | tr 'A-Z' 'a-z')" = "$(echo "$2" | tr 'A-Z' 'a-z')" ]; }

echo "ask for a sign-up code"
STATUS=$(code /v1/auth/signup "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"displayName\":\"Probe\"}")
SENT=$(cat /tmp/.deylee-smoke)
# A 502 means the row was written and Resend refused the send — still proof the
# first half worked, and the planted code below makes the rest testable anyway.
[ "$STATUS" = "200" ] || [ "$STATUS" = "502" ] \
  && ok "code requested ($STATUS)" || bad "requesting a code failed ($STATUS): $SENT"
N=$(psql "$DBURL?connect_timeout=15" -tAc \
  "select count(*) from public.app_users where email = '$EMAIL'")
[ "$N" = "0" ] \
  && ok "no account exists yet — nothing to adopt before the code comes back" \
  || bad "an account was created before the code was checked, which is the whole bug"

echo "verify the code"
# The route mails the code and a smoke test has no mailbox, so a known one is
# planted through the same function the route calls. Everything after this is the
# real HTTP path, and the cooldown is set to 0 so the plant is not refused.
OTP="424242"
psql "$DBURL?connect_timeout=15" -tAc \
  "select public.auth_request_signup_code('$EMAIL','$PASS','Probe','UTC','$OTP',600,0)" >/dev/null
STATUS=$(code /v1/auth/signup/verify "{\"email\":\"$EMAIL\",\"code\":\"000000\"}")
[ "$STATUS" = "401" ] && ok "a wrong code is refused" \
  || bad "a wrong code was accepted (got $STATUS)"
OUT=$(post /v1/auth/signup/verify "{\"email\":\"$EMAIL\",\"code\":\"$OTP\"}")
USER=$(echo "$OUT" | field "['user']['id']")
REFRESH=$(echo "$OUT" | field "['refreshToken']")
ACCESS=$(echo "$OUT" | field "['accessToken']")
[ -n "$USER" ] && ok "account created" || { bad "verification failed: $OUT"; exit 1; }
[ "$USER" = "$(echo "$USER" | tr 'A-Z' 'a-z')" ] \
  && ok "the id is lower case, matching what clients store" \
  || bad "the id came back upper case, which would duplicate every synced row"
V=$(psql "$DBURL?connect_timeout=15" -tAc \
  "select email_verified from public.app_users where id = '$USER'")
[ "$V" = "t" ] \
  && ok "and it is verified, so google has nothing unverified to adopt" \
  || bad "the account was created unverified"

echo "the spent code cannot be replayed"
STATUS=$(code /v1/auth/signup/verify "{\"email\":\"$EMAIL\",\"code\":\"$OTP\"}")
[ "$STATUS" = "401" ] && ok "refused — the pending row is gone" \
  || bad "a used code worked twice (got $STATUS)"

echo "sign up again with the same address"
STATUS=$(code /v1/auth/signup "{\"email\":\"$EMAIL\",\"password\":\"different\"}")
[ "$STATUS" = "409" ] \
  && ok "refused — this is what stops a stranger claiming your address" \
  || bad "a second sign-up on one address was allowed (got $STATUS)"

echo "sign in"
same "$(post /v1/auth/password "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | field "['user']['id']")" "$USER" \
  && ok "same account" || bad "sign-in reached a different account"
same "$(post /v1/auth/password "{\"email\":\"$(echo "$EMAIL" | tr 'a-z' 'A-Z')\",\"password\":\"$PASS\"}" | field "['user']['id']")" "$USER" \
  && ok "capitals in the address still reach it" || bad "case created a second account"

echo "reject bad credentials"
STATUS=$(code /v1/auth/password "{\"email\":\"$EMAIL\",\"password\":\"wrong\"}")
WRONG=$(cat /tmp/.deylee-smoke)
[ "$STATUS" = "401" ] && ok "wrong password refused" \
  || bad "a wrong password was accepted (got $STATUS)"

STATUS=$(code /v1/auth/password "{\"email\":\"nobody-$RUN@deylee-smoke.invalid\",\"password\":\"whatever\"}")
UNKNOWN=$(cat /tmp/.deylee-smoke)
[ "$STATUS" = "401" ] && ok "unknown address refused" \
  || bad "an unknown address was accepted (got $STATUS)"

[ "$WRONG" = "$UNKNOWN" ] \
  && ok "both say the same thing, so addresses cannot be enumerated" \
  || bad "the two answers differ, which reveals which addresses exist"

echo "and take the same time, which the bodies alone never proved"
# The bodies matched long before the clock did. A known address ran bcrypt at cost 12,
# an unknown one skipped it entirely, and the ~200 ms gap enumerated accounts over the
# internet without averaging. Sampled rather than timed once, because a single request
# is mostly network.
#
# Three each, alternating, so a drifting machine cannot bias one side. Kept small on
# purpose: the auth routes are rate limited now and a long run would trip the cap this
# script also relies on not hitting.
elapsed() {   # elapsed <email> -> milliseconds for one attempt
  local t0 t1
  t0=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  post /v1/auth/password "{\"email\":\"$1\",\"password\":\"definitely-wrong\"}" >/dev/null
  t1=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
  perl -e "printf '%d', ($t1 - $t0) * 1000"
}

KNOWN=(); UNKNOWN=()
for i in 1 2 3 4 5; do
  KNOWN+=("$(elapsed "$EMAIL")")
  UNKNOWN+=("$(elapsed "nobody-$i-$RANDOM@deylee-smoke.invalid")")
done
# Medians, not means: one request caught behind a checkpoint or a garbage collection
# drags a mean by more than the effect being measured.
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
spread() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {print a[NR]-a[1]}'; }
KNOWN_MS=$(median "${KNOWN[@]}"); UNKNOWN_MS=$(median "${UNKNOWN[@]}")
GAP=$(( KNOWN_MS > UNKNOWN_MS ? KNOWN_MS - UNKNOWN_MS : UNKNOWN_MS - KNOWN_MS ))

# The unknown samples all take the same path, so their own spread is this link's
# noise floor — measured on the run rather than assumed. The signal being looked for
# is a whole bcrypt, about 200 ms; when the noise is that size the measurement cannot
# resolve it and a verdict either way would be invented. Against the production tunnel
# each request is ~1.5 s of network and the floor lands in the hundreds, which is why
# this check used to fail at random there while the property itself was fine.
JITTER=$(spread "${UNKNOWN[@]}")
if [ "$JITTER" -ge 100 ]; then
  echo "  skip  the link jitters ${JITTER}ms, which hides a ~200ms bcrypt — run against a local API to test this"
elif [ "$GAP" -lt 100 ]; then
  ok "known ${KNOWN_MS}ms vs unknown ${UNKNOWN_MS}ms — ${GAP}ms apart, no timing oracle"
else
  bad "known ${KNOWN_MS}ms vs unknown ${UNKNOWN_MS}ms — ${GAP}ms apart, addresses are enumerable by clock"
fi

echo "rotate the refresh token"
NEXT=$(post /v1/auth/refresh "{\"refreshToken\":\"$REFRESH\"}" | field "['refreshToken']")
[ -n "$NEXT" ] && [ "$NEXT" != "$REFRESH" ] && ok "rotated" || bad "rotation did not issue a new token"
STATUS=$(code /v1/auth/refresh "{\"refreshToken\":\"$REFRESH\"}")
[ "$STATUS" = "401" ] && ok "the spent token is refused" \
  || bad "a spent token still worked (got $STATUS)"
STATUS=$(code /v1/auth/refresh "{\"refreshToken\":\"$NEXT\"}")
[ "$STATUS" = "401" ] && ok "and its successor is dead too — a replay kills the whole chain" \
  || bad "the successor survived a replay, so a thief keeps access (got $STATUS)"

echo "link a google identity to the same account"
# The route needs a real Google ID token, which needs a browser. The linking rule
# lives in the function the route calls, so it is exercised directly here; token
# verification is covered by the API's own suite.
LINKED=$(psql "$DBURL?connect_timeout=15" -tAc \
  "select id from public.auth_sign_in_with_google('smoke-google-sub','$EMAIL',true,'Probe G','UTC')")
same "$LINKED" "$USER" && ok "google landed on the existing account" \
  || bad "google created a second account for one person"
N=$(psql "$DBURL?connect_timeout=15" -tAc \
  "select count(*) from public.user_identities where user_id = '$USER'")
[ "$N" = "2" ] && ok "the account now has both identities" || bad "expected 2 identities, saw $N"
same "$(post /v1/auth/password "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | field "['user']['id']")" "$USER" \
  && ok "the password still reaches it afterwards" || bad "linking broke password sign-in"

echo "add a password from inside a session"
# The replay above revoked this chain, and a revoked chain's access tokens are now
# refused for the rest of their hour rather than honoured until they expire. That is
# the whole point of the change, so it is asserted here rather than stepped around —
# this check used to pass only because the token outlived its session.
setPassword() {   # setPassword <token> -> HTTP status
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$API/v1/auth/set-password" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    --data-raw '{"password":"a-replacement-password"}'
}
STATUS=$(setPassword "$ACCESS")
[ "$STATUS" = "401" ] && ok "the revoked session's access token is refused" \
  || bad "a revoked session could still act (got $STATUS)"

# A live session, the way the app would have one after signing in again.
ACCESS=$(post /v1/auth/password "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}" | field "['accessToken']")
[ "$(setPassword "$ACCESS")" = "200" ] \
  && ok "accepted" || bad "a signed-in user could not set a password"
same "$(post /v1/auth/password "{\"email\":\"$EMAIL\",\"password\":\"a-replacement-password\"}" | field "['user']['id']")" "$USER" \
  && ok "the new password signs into the same account" || bad "the replacement password did not work"

echo "pre-registration takeover cannot survive a google sign-in"
# The scenario from the audit, in one address:
#
#   Mallory registers alice's address and picks a password. Alice has never used
#   Deylee. Alice later signs in with Google, is handed that account, and starts
#   tracking. Mallory's password still works, from any device, indefinitely.
#
# Nothing can create an unverified account through the API any more, so the row is
# planted as the old sign-up would have left it — which is also exactly what is
# already sitting in the database from before the fix.
VICTIM="victim-$RUN@deylee-smoke.invalid"
psql "$DBURL?connect_timeout=15" -tA >/dev/null <<SQL
insert into public.app_users (email, email_verified, timezone, last_seen_at)
values ('$VICTIM', false, 'UTC', public.epoch_ms());
insert into public.user_identities (user_id, provider, subject, password_hash)
select id, 'password', '$VICTIM',
       extensions.crypt('mallorys-password', extensions.gen_salt('bf', 10))
  from public.app_users where email = '$VICTIM';
SQL
same "$(post /v1/auth/password "{\"email\":\"$VICTIM\",\"password\":\"mallorys-password\"}" \
        | field "['user']['email']")" "$VICTIM" \
  && ok "the planted password works before the handover, as it did in the report" \
  || bad "the probe row was not set up as expected"

# Alice arrives with Google.
psql "$DBURL?connect_timeout=15" -tAc \
  "select public.auth_sign_in_with_google('smoke-victim-sub','$VICTIM',true,'Alice','UTC')" >/dev/null

STATUS=$(code /v1/auth/password "{\"email\":\"$VICTIM\",\"password\":\"mallorys-password\"}")
[ "$STATUS" = "401" ] \
  && ok "and is dead afterwards — the unverified credential did not survive" \
  || bad "TAKEOVER: the pre-registered password still signs in (got $STATUS)"
N=$(psql "$DBURL?connect_timeout=15" -tAc \
  "select count(*) from public.user_identities i join public.app_users u on u.id = i.user_id
    where u.email = '$VICTIM' and i.provider = 'password'")
[ "$N" = "0" ] && ok "the password identity is gone, not merely unusable" \
  || bad "$N password identities survived the handover"

echo "a google address moving onto a registered one is named, not a 500"
# Two accounts, then the first changes its Google address to the second's. The
# update behind that used to hit app_users_one_per_email and raise a bare 23505,
# which matched no sentinel and became an opaque 500 — permanently, on every later
# Continue with Google. Exercised through the function for the same reason as the
# linking check above: the route needs a real Google ID token.
ONE="collide-one-$RUN@deylee-smoke.invalid"
TWO="collide-two-$RUN@deylee-smoke.invalid"
psql "$DBURL?connect_timeout=15" -tAc \
  "select public.auth_sign_in_with_google('smoke-collide-1','$ONE',true,'One','UTC')" >/dev/null
psql "$DBURL?connect_timeout=15" -tAc \
  "select public.auth_sign_in_with_google('smoke-collide-2','$TWO',true,'Two','UTC')" >/dev/null

RAISED=$(psql "$DBURL?connect_timeout=15" -tAc \
  "do \$\$ begin
     perform public.auth_sign_in_with_google('smoke-collide-1','$TWO',true,'One','UTC');
     raise notice 'none';
   exception when others then raise notice '%', sqlerrm;
   end \$\$;" 2>&1 | sed -n 's/^NOTICE:  //p')
[ "$RAISED" = "email-collision" ] \
  && ok "refused as email-collision, which the API can turn into a 409" \
  || bad "expected email-collision, got: $RAISED"

# The bare constraint name is what made this a 500. If it ever comes back, the
# message is the tell.
case "$RAISED" in
  *"duplicate key"*|*"app_users_one_per_email"*)
    bad "the raw unique violation escaped again — this is the 500" ;;
  *) ok "no raw constraint text escaped" ;;
esac

same "$(psql "$DBURL?connect_timeout=15" -tAc "select email from public.app_users where email='$ONE'")" "$ONE" \
  && ok "and neither account was altered by the attempt" \
  || bad "the refused sign-in still changed an address"

echo "an ordinary google address change still goes through"
same "$(psql "$DBURL?connect_timeout=15" -tAc \
  "select email from public.auth_sign_in_with_google('smoke-collide-1','collide-moved-$RUN@deylee-smoke.invalid',true,'One','UTC')")" \
  "collide-moved-$RUN@deylee-smoke.invalid" \
  && ok "the account followed the new address" \
  || bad "a legitimate address change was refused"

rm -f /tmp/.deylee-smoke

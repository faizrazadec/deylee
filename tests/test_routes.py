"""The auth surface as a client meets it.

Everything else tests a function. These send a request through the real app and read the
status back, which is the only way to catch the layer between them: a refusal the database
raises correctly and the error mapping then reports as a 500, a route that decodes a body
wrong, an `Authorization` header nobody checks.

Requests go straight into the ASGI app rather than over a socket — no port, no listener,
and the lifespan does not run, which is why the store is started by hand here and why the
tenancy suite asserts the connected role separately.

Needs a database for the same reason the tenancy tests do: every route here reaches one,
and the interesting answers (409, 429, 400) come from constraints and SECURITY DEFINER
functions rather than from Python. Set `DEYLEE_TEST_DB_URL` to the **restricted** login —
see `test_tenancy.py` for the rest. Skipped without it, and that gap is real: unset the
variable and none of this is checked.

Every case below fails *before* any mail is sent, so no Resend key is needed. That is a
deliberate limit — the happy path of sign-up is not covered here — and `RecordingMailer`
is what keeps the claim honest rather than assumed.

Nothing is torn down. The one account these create is keyed to a fixed Google subject, so
a run reuses it instead of leaving a new one behind, and `deylee_api` holds no DELETE
grant on `app_users` anyway — being bound by the permissions under test is the point.
"""

import logging
from collections.abc import AsyncIterator
from uuid import UUID

import httpx
import pytest
from conftest import TEST_DB_URL, load_env, requires_db, valid_env

from deylee_api.app import create_app
from deylee_api.db import Store
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.tokens import TokenService

pytestmark = requires_db

LOGGER = logging.getLogger("route-test")

#: Addresses mail was attempted to. Module-level because the assertion is "none", and one
#: list is less machinery than threading a spy through every fixture.
SENT: list[str] = []


class RecordingMailer(Mailer):
    """A mailer that records instead of sending.

    Not a convenience: a route test that reached Resend would send real mail from a test
    run, and the suite's claim that nothing here gets that far would be unverified.
    """

    async def send_signup_code(self, code: str, to: str) -> None:
        SENT.append(to)


@pytest.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
    """The app as `__main__` assembles it, minus the parts a request never reaches here.

    A fresh `RateLimiter` per app, so one test's attempts cannot throttle another's.
    """
    assert TEST_DB_URL is not None
    SENT.clear()
    config = load_env(valid_env(DEYLEE_DB_URL=TEST_DB_URL))
    store = Store(TEST_DB_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    app = create_app(
        config=config,
        store=store,
        tokens=TokenService(config),
        mailer=RecordingMailer(
            api_key=config.resend_api_key,
            sender=config.resend_from,
            template_id=config.resend_otp_template_id,
            logger=LOGGER,
        ),
        limiter=RateLimiter(),
        logger=LOGGER,
        assert_rls=False,
    )
    await store.start()
    try:
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as connected:
            yield connected
    finally:
        await store.close()


async def seed_google_account(sub: str, email: str) -> UUID:
    """An account, made through the Google route's own function — the only way the
    restricted role can create one. A fixed subject, so this reuses the account rather than
    leaving a new one behind on every run."""
    assert TEST_DB_URL is not None
    store = Store(TEST_DB_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await store.start()
    try:
        async with store.without_tenant() as connection:
            return await connection.fetchval(
                "SELECT id FROM public.auth_sign_in_with_google($1, $2, true, 'Probe', 'UTC')",
                sub,
                email,
            )
    finally:
        await store.close()


# ------------------------------------------------------------------ Password sign-in


async def test_bad_credentials_are_refused_identically_to_unknown_ones(client):
    """Wrong password and unknown address answer identically, so the response cannot be
    used to learn which addresses are registered. Asserted through the route because it is
    the route that turns both into a body."""
    wrong = await client.post(
        "/v1/auth/password",
        json={"email": "nobody@routes.invalid", "password": "whatever1"},
    )
    also_wrong = await client.post(
        "/v1/auth/password",
        json={"email": "someone-else@routes.invalid", "password": "whatever1"},
    )

    assert wrong.status_code == 401
    assert also_wrong.status_code == 401
    assert wrong.text == also_wrong.text, "the two answers must not differ"


# ------------------------------------------------------------------------- Sign-out


async def test_sign_out_without_a_token_is_refused(client):
    """Sign-out revokes a session and must therefore prove which one. Without a token there
    is no `sid` to act on, and a route that shrugged and answered 200 would read as a
    successful sign-out to every client."""
    missing = await client.post("/v1/auth/signout", json={})
    assert missing.status_code == 401

    garbage = await client.post(
        "/v1/auth/signout", json={}, headers={"Authorization": "Bearer not-a-jwt"}
    )
    assert garbage.status_code == 401


# --------------------------------------------------------------------------- Google


async def test_google_sign_in_without_a_nonce_is_refused(client):
    """The nonce binds the ID token to the authorization request that asked for it.

    It has to be required rather than checked-when-present: the body is the caller's to
    write, so an optional one is an optional an attacker omits, and the binding would hold
    only for the clients that were never the threat.

    Refused before the token is looked at, so this needs no Google key set.
    """
    missing = await client.post("/v1/auth/google", json={"idToken": "whatever", "timezone": "UTC"})
    assert missing.status_code == 400

    empty = await client.post(
        "/v1/auth/google", json={"idToken": "whatever", "timezone": "UTC", "nonce": ""}
    )
    assert empty.status_code == 400, "an empty nonce binds nothing"


async def test_a_malformed_body_is_rejected_not_crashed(client):
    """A body the route cannot decode is the client's fault, not the server's. It used to
    be easy for this to surface as a 500 — and FastAPI's own instinct is a 422, which is a
    status the protocol does not have."""
    response = await client.post("/v1/auth/password", json={"email": "only-half"})
    assert response.status_code == 400


# ------------------------------------------------------------------- Sign-up refusals


async def test_a_weak_password_is_400(client):
    """bcrypt ignores anything past 72 bytes, which would make two long passwords
    interchangeable, so the function refuses rather than truncating — and the route has to
    report that as something the person can act on."""
    response = await client.post(
        "/v1/auth/signup", json={"email": "weak@routes.invalid", "password": "short"}
    )
    assert response.status_code == 400
    assert SENT == [], "a short password must not reach the mailer"


async def test_a_taken_address_is_409(client):
    """An address that already has an account is a 409 and not a 500.

    The mapping switches on the message a SECURITY DEFINER function raises, and a sentinel
    missing from that switch is exactly how this became an opaque 500 twice.
    """
    await seed_google_account("route-test-taken", "taken@routes.invalid")

    response = await client.post(
        "/v1/auth/signup",
        json={"email": "taken@routes.invalid", "password": "a-good-password"},
    )
    assert response.status_code == 409
    assert SENT == [], "a refused sign-up must not mail the address either"


# --------------------------------------------------------------------- Bearer tokens


@pytest.mark.parametrize(
    "header", [None, "Bearer not-a-jwt", "Basic abc", "bearer wrong-scheme-case"]
)
async def test_set_password_refuses_every_bad_header(client, header: str | None):
    """`set-password` is the one route that trusts a session, so the header is the whole of
    its security. Absent, malformed and forged must all be refused — including a lower-case
    scheme, which is a comparison somebody is always tempted to loosen."""
    headers = {} if header is None else {"Authorization": header}
    response = await client.post(
        "/v1/auth/set-password", json={"password": "a-good-password"}, headers=headers
    )
    assert response.status_code == 401, f"accepted: {header}"


async def test_an_unknown_refresh_token_is_refused(client):
    """A refresh token nobody issued must not mint a session, and must answer the same as a
    spent one so a thief learns nothing from the difference."""
    response = await client.post("/v1/auth/refresh", json={"refreshToken": "invented"})
    assert response.status_code == 401


async def test_a_wrong_signup_code_is_refused_not_a_fault(client):
    """A wrong code is a refusal the route reports, not a 500.

    The verify function answers with an outcome rather than raising, because a raise would
    roll back the attempt counter it had just incremented — the cap would read as enforced
    while a script guessed six digits at its leisure. A 500 here is the sign that path was
    lost.
    """
    response = await client.post(
        "/v1/auth/signup/verify", json={"email": "x@routes.invalid", "code": "000000"}
    )
    assert response.status_code == 401


# ------------------------------------------------------------------------ Throttling


async def test_repeated_attempts_are_throttled_with_retry_after(client):
    """Every password attempt costs a quarter-second of database CPU by design, so an
    unauthenticated caller converts one cheap request into real money. Unlimited attempts
    is the DoS; the 429 is the cap."""
    retry_after: str | None = None

    # The per-address limit is 10 in five minutes and bites first.
    for _ in range(14):
        response = await client.post(
            "/v1/auth/password",
            json={"email": "throttle@routes.invalid", "password": "whatever1"},
        )
        if response.status_code == 429:
            retry_after = response.headers.get("Retry-After")
            break
        assert response.status_code == 401, "before the cap, a bad password is a 401"

    assert retry_after is not None, "unlimited attempts against one account"
    # The protocol says Retry-After is authoritative, so it has to be there and has to be a
    # number a client can wait for. `Retry-After: 0` invites an immediate refusal.
    assert retry_after.isdigit(), f"Retry-After unparseable: {retry_after!r}"
    assert int(retry_after) > 0

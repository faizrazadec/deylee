"""The one route a stranger can write through.

Everything else in this API is reached with a token, so the interesting questions here
are the ones an account normally answers: what stops a script, what stops a malformed
address becoming a 500, and what the table ends up holding.

Needs a database, like the rest of the route tests — the refusals worth checking come
from the constraints and the SECURITY DEFINER function rather than from Python, and the
per-address allowance cannot be observed without rows. Set `DEYLEE_TEST_DB_URL` to the
**restricted** login; skipped without it, and that gap is real.

Addresses are unique per test so a re-run does not trip the previous run's allowance, and
the waitlist's idempotency test uses one address deliberately twice.
"""

import logging
from collections.abc import AsyncIterator
from uuid import uuid4

import httpx
import pytest
from conftest import (
    TEST_DB_OWNER_URL,
    TEST_DB_URL,
    load_env,
    requires_db,
    requires_owner_db,
    valid_env,
)

from deylee_api.app import create_app
from deylee_api.db import Store
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.tokens import TokenService

pytestmark = requires_db

LOGGER = logging.getLogger("contact-test")

SITE = "https://deylee.faizraza.me"


class SilentMailer(Mailer):
    """Nothing on this route sends mail. Here so that claim is enforced rather than
    assumed — a send would raise instead of quietly reaching Resend from a test run."""

    async def send_signup_code(self, code: str, to: str) -> None:
        raise AssertionError("the contact route must not send mail")


@pytest.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
    """A fresh `RateLimiter` per app, so one test's submissions cannot throttle another's."""
    assert TEST_DB_URL is not None
    config = load_env(valid_env(DEYLEE_DB_URL=TEST_DB_URL, WEB_ORIGIN=SITE))
    store = Store(TEST_DB_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    app = create_app(
        config=config,
        store=store,
        tokens=TokenService(config),
        mailer=SilentMailer(
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


def an_address() -> str:
    return f"{uuid4().hex}@contact.invalid"


async def rows_for(email: str) -> list[tuple[str, str | None, str | None]]:
    """What the table actually holds, read as the owner.

    `deylee_api` has no select grant — that is the point of the design, and the reason
    this needs a second login rather than the one the routes use.
    """
    assert TEST_DB_OWNER_URL is not None
    store = Store(TEST_DB_OWNER_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await store.start()
    try:
        async with store.without_tenant() as connection:
            found = await connection.fetch(
                "SELECT kind, team_size, message FROM public.contact_requests "
                "WHERE email = $1 ORDER BY id",
                email,
            )
    finally:
        await store.close()
    return [(row["kind"], row["team_size"], row["message"]) for row in found]


# --------------------------------------------------------------------- The happy paths
#
# The per-address allowance is three an hour, counted in rows, which makes it a way to
# observe how many rows a sequence of requests actually wrote — without a select grant the
# API role does not have. That is what the first three below lean on: a fourth request
# answering 200 means the earlier ones collapsed into one row, and 429 means they did not.


async def test_a_waitlist_signup_is_accepted(client):
    response = await client.post("/v1/contact", json={"kind": "teams", "email": an_address()})

    assert response.status_code == 200
    assert response.json() == {"accepted": True}


async def test_joining_the_waitlist_repeatedly_leaves_one_row(client):
    """Pressing the button again is not an error and must not be a second row.

    Four goes, all accepted. If each had written a row the fourth would be over the
    per-address allowance and refused, so the 200 is the assertion.
    """
    email = an_address()
    codes = [
        (await client.post("/v1/contact", json={"kind": "teams", "email": email})).status_code
        for _ in range(4)
    ]

    assert codes == [200, 200, 200, 200]


async def test_the_address_is_folded_and_trimmed_before_anything_looks_at_it(client):
    """Two spellings of one mailbox are one person, on both routes.

    Three Enterprise enquiries spelled three ways, then a fourth. If folding did not
    happen each spelling would carry its own count and the fourth would be accepted; the
    429 is what proves they were counted as one address.
    """
    email = an_address()
    for spelling in (email, email.upper(), f"  {email.capitalize()}  "):
        sent = await client.post(
            "/v1/contact", json={"kind": "enterprise", "email": spelling, "message": "hello"}
        )
        assert sent.status_code == 200, spelling

    fourth = await client.post(
        "/v1/contact", json={"kind": "enterprise", "email": email, "message": "hello"}
    )
    assert fourth.status_code == 429


async def test_a_second_enterprise_enquiry_is_a_second_row(client):
    """The waitlist's idempotency is deliberately partial. A second enquiry from an address
    that already wrote is a second thing somebody wants to say, not a duplicate — so unlike
    the waitlist, four Enterprise messages do reach the allowance."""
    email = an_address()
    codes = [
        (
            await client.post(
                "/v1/contact",
                json={"kind": "enterprise", "email": email, "message": f"note {n}"},
            )
        ).status_code
        for n in range(4)
    ]

    assert codes == [200, 200, 200, 429]


# ------------------------------------------------------- What actually lands in the table
#
# These need the owner login, because the whole design of the table is that the API role
# holds no grant on it. Skipped without DEYLEE_TEST_DB_OWNER_URL, which `./scripts/dev-db.sh`
# prints — and that gap is real: without it, nothing checks which columns are written.


@requires_owner_db
async def test_the_waitlist_stores_only_the_address(client):
    """The Teams route asks for one thing and must keep one thing. A headcount or a message
    arriving on it is a client that has drifted, and storing them anyway would put fields in
    the table that the form never showed the person."""
    email = an_address()
    response = await client.post(
        "/v1/contact",
        json={"kind": "teams", "email": email, "teamSize": "21–100", "message": "ignore me"},
    )

    assert response.status_code == 200
    assert await rows_for(email) == [("teams", None, None)]


@requires_owner_db
async def test_an_enterprise_enquiry_keeps_the_headcount_and_the_message(client):
    email = an_address()
    response = await client.post(
        "/v1/contact",
        json={
            "kind": "enterprise",
            "email": email,
            "teamSize": "More than 100",
            "message": "Payroll exports, and a self-hosted sync server.",
        },
    )

    assert response.status_code == 200
    assert await rows_for(email) == [
        ("enterprise", "More than 100", "Payroll exports, and a self-hosted sync server.")
    ]


@requires_owner_db
async def test_the_stored_address_is_the_folded_one(client):
    """The behavioural test above proves the two spellings were counted as one. This is the
    other half: the row itself carries the folded, trimmed form, so a list exported from
    here does not hold three spellings of one person."""
    email = an_address()
    await client.post("/v1/contact", json={"kind": "teams", "email": f"  {email.upper()}  "})

    assert await rows_for(email) == [("teams", None, None)]


@requires_owner_db
async def test_a_correction_keeps_the_message_but_no_headcount(client):
    """The third route. A correction has something to say and no team size, so the message
    is kept and a headcount posted alongside it is dropped — the same split the form draws,
    enforced where it cannot be bypassed by a client that drifted."""
    email = an_address()
    response = await client.post(
        "/v1/contact",
        json={
            "kind": "fix",
            "email": email,
            "teamSize": "More than 100",
            "message": "The pricing page says Teams is available. It is not.",
        },
    )

    assert response.status_code == 200
    assert await rows_for(email) == [
        ("fix", None, "The pricing page says Teams is available. It is not.")
    ]


async def test_two_corrections_are_two_rows(client):
    """Two reports from one address are two things somebody noticed, so the waitlist's
    idempotency must not reach this route — the fourth inside the hour is the allowance,
    which is the proof the first three were all written."""
    email = an_address()
    codes = [
        (
            await client.post(
                "/v1/contact", json={"kind": "fix", "email": email, "message": f"bug {n}"}
            )
        ).status_code
        for n in range(4)
    ]

    assert codes == [200, 200, 200, 429]


# ------------------------------------------------------------------------- The refusals


async def test_a_malformed_address_is_400_not_500(client):
    """The column has a shape constraint, and a constraint violation reaches the client as
    an opaque 500. The route has to refuse first, in words the person can act on."""
    for bad in ("not-an-address", "no@domain", "two @spaces.com", ""):
        response = await client.post("/v1/contact", json={"kind": "teams", "email": bad})
        assert response.status_code == 400, bad
        assert "error" in response.json()


async def test_an_unknown_kind_is_refused(client):
    """`kind` decides how the row is read later. Anything outside the two the form sends is
    a client that has drifted, and inventing a third route by posting one is not on."""
    response = await client.post("/v1/contact", json={"kind": "partnership", "email": an_address()})
    assert response.status_code == 400


async def test_a_body_missing_its_fields_is_400(client):
    """FastAPI's instinct is a 422 with its own envelope; the contract says 400 with ours."""
    response = await client.post("/v1/contact", json={"email": an_address()})
    assert response.status_code == 400
    assert "error" in response.json()


async def test_a_message_far_past_the_column_is_413(client):
    """Refused on the wire rather than by the constraint, so the answer names the problem."""
    response = await client.post(
        "/v1/contact",
        json={"kind": "enterprise", "email": an_address(), "message": "x" * 30_000},
    )
    assert response.status_code == 413


async def test_one_address_cannot_be_used_as_a_notepad(client):
    """Three an hour per address, counted in the database rather than in this process, so
    it holds across restarts and across replicas. The fourth is refused."""
    email = an_address()
    codes = [
        (
            await client.post(
                "/v1/contact",
                json={"kind": "enterprise", "email": email, "message": f"note {n}"},
            )
        ).status_code
        for n in range(4)
    ]

    assert codes == [200, 200, 200, 429]
    assert len(await rows_for(email)) == 3


async def test_one_source_cannot_flood_the_table(client):
    """The per-address allowance is defeated by a script that cycles addresses, so the
    route meters the caller too — ten an hour, well under the 600 a minute the global
    limiter allows a syncing client."""
    sent = [
        (
            await client.post(
                "/v1/contact",
                json={"kind": "teams", "email": an_address()},
                headers={"CF-Connecting-IP": "203.0.113.9"},
            )
        ).status_code
        for _ in range(11)
    ]

    assert sent[:10] == [200] * 10
    assert sent[10] == 429


# ------------------------------------------------------------------------------- CORS


async def test_the_site_may_post_from_a_browser(client):
    """The form is a cross-origin POST from a static export on another host. Without the
    allow-origin header the browser discards the answer and the button does nothing."""
    response = await client.post(
        "/v1/contact",
        json={"kind": "teams", "email": an_address()},
        headers={"Origin": SITE},
    )

    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == SITE


async def test_another_origin_is_not_granted_access(client):
    """An allow-list, not a wildcard. The header is what a browser enforces on, so its
    absence for an unlisted origin is the whole control."""
    response = await client.post(
        "/v1/contact",
        json={"kind": "teams", "email": an_address()},
        headers={"Origin": "https://not-the-site.invalid"},
    )

    assert "access-control-allow-origin" not in response.headers


async def test_a_preflight_is_answered(client):
    """The browser sends OPTIONS on its own before a JSON POST. It must not be counted
    against the caller's allowance, and it must not 405."""
    response = await client.options(
        "/v1/contact",
        headers={
            "Origin": SITE,
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type",
        },
    )

    assert response.status_code == 200
    assert response.headers.get("access-control-allow-origin") == SITE

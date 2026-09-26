"""Hour slips: issued only for ended days, signed, and checkable by anyone holding one.

What must hold: an hour slip's claimed hours are the day's work segments, its witnessed hours
are the beats the server stamped, split by the person's own local days (a run across their
midnight belongs to both days); the check page confirms a genuine hour slip and refuses a
forged or altered one; and an hour slip is refused for a day that has not ended, for more than
30 days, or on a server with no hour slip key.

The witness beats are planted as the owner — nothing else may write that table, and it only
ever takes the present — so this suite needs both database logins. A fresh account per
test, dated ten days back in Europe/Berlin, so every day under test has long since locked.
"""

import base64
import logging
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime, timedelta
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

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
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import FastAPI

from deylee_api.app import create_app
from deylee_api.db import Store
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.routes.hour_slips import _day_window
from deylee_api.tokens import TokenService

pytestmark = [requires_db, requires_owner_db]
LOGGER = logging.getLogger("hour-slips-test")
BERLIN = ZoneInfo("Europe/Berlin")
DAY = (datetime.now(BERLIN) - timedelta(days=10)).date()
NEXT = DAY + timedelta(days=1)
MIN = 60_000


def local_ms(d: date, hour: int, minute: int = 0, second: int = 0) -> int:
    """From calendar components in Berlin, never an offset added to a midnight."""
    return int(datetime(d.year, d.month, d.day, hour, minute, second, tzinfo=BERLIN)
               .astimezone(UTC).timestamp() * 1000)


def hour_slip_key_b64() -> str:
    pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    return base64.b64encode(pem).decode()


def build(store: Store, **env: str) -> FastAPI:
    config = load_env(valid_env(**env))
    return create_app(
        config=config, store=store, tokens=TokenService(config),
        mailer=Mailer(api_key=config.resend_api_key, sender=config.resend_from,
                      template_id=config.resend_otp_template_id, logger=LOGGER),
        limiter=RateLimiter(), logger=LOGGER, assert_rls=False,
    )


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    assert TEST_DB_URL is not None
    s = Store(TEST_DB_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await s.start()
    try:
        yield s
    finally:
        await s.close()


@pytest.fixture
async def owner() -> AsyncIterator[Store]:
    assert TEST_DB_OWNER_URL is not None
    s = Store(TEST_DB_OWNER_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await s.start()
    try:
        yield s
    finally:
        await s.close()


class Person:
    def __init__(self, client: httpx.AsyncClient, token: str, user: UUID, email: str):
        self.client, self.token, self.user, self.email = client, token, user, email

    async def hour_slip(self, first: date, last: date, zone: str = "Europe/Berlin"):
        return await self.client.post(
            "/v1/hour-slips", headers={"Authorization": f"Bearer {self.token}"},
            json={"from": first.isoformat(), "to": last.isoformat(), "timeZone": zone},
        )


async def sign_up(app: FastAPI, store: Store) -> tuple[UUID, str, str]:
    subject = f"hour-slip-{uuid4()}"
    email = f"{subject}@slips.invalid"
    async with store.without_tenant() as connection:
        user = await connection.fetchval(
            "SELECT id FROM public.auth_sign_in_with_google($1, $2, true, 'Hour Slip', 'UTC')",
            subject, email,
        )
    return user, await app.state.tokens.issue_access_token(user, uuid4()), email


@pytest.fixture
async def person(store: Store, owner: Store) -> AsyncIterator[Person]:
    """Seven hours of work on DAY (two segments either side of a break), and witness beats:
    an hour from 09:00, then a run across midnight into NEXT."""
    app = build(store, HOUR_SLIP_SIGNING_KEY_B64=hour_slip_key_b64(),
                DEYLEE_PUBLIC_URL="https://slips.test")
    user, token, email = await sign_up(app, store)
    async with store.with_user(user) as connection:
        for start, end, kind in [
            (local_ms(DAY, 9), local_ms(DAY, 12), "work"),
            (local_ms(DAY, 12), local_ms(DAY, 12, 30), "break"),
            (local_ms(DAY, 13), local_ms(DAY, 17), "work"),
        ]:
            await connection.execute(
                "INSERT INTO public.segments (id, user_id, day_date, type, started_at, ended_at, "
                "created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $5, $6)",
                uuid4(), user, DAY.isoformat(), kind, start, end,
            )
    beats = [local_ms(DAY, 9) + 30_000 * i for i in range(121)]            # 09:00–10:00
    beats += [local_ms(DAY, 23, 59, 30), local_ms(NEXT, 0), local_ms(NEXT, 0, 0, 30)]
    async with owner.without_tenant() as connection:
        await connection.executemany(
            "INSERT INTO public.witness_beats (user_id, beat_at) VALUES ($1, $2)",
            [(user, b) for b in beats],
        )
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield Person(client, token, user, email)


# MARK: Issuing


async def test_an_hour_slip_carries_claimed_and_witnessed_hours_by_local_day(person: Person):
    response = await person.hour_slip(DAY, NEXT)
    assert response.status_code == 200, response.text
    hour_slip = response.json()

    first, second = hour_slip["days"]
    assert first["claimedMs"] == 7 * 60 * MIN, "work only: the break is not claimed"
    # The hour from 09:00, then 23:59:30 (credited 45 s back, all on DAY) and the 30 s up
    # to midnight. The first beat ever vouches for nothing.
    assert first["witnessedMs"] == 60 * MIN + 45_000 + 30_000
    assert second == {"date": NEXT.isoformat(), "claimedMs": 0, "witnessedMs": 30_000,
                      "witnessedApproximate": False}
    assert hour_slip["claimedMs"] == 7 * 60 * MIN
    assert hour_slip["witnessedMs"] == 60 * MIN + 105_000
    assert hour_slip["email"] == person.email
    assert hour_slip["url"].startswith("https://slips.test/slip/")


async def test_a_day_that_has_not_ended_is_refused(person: Person):
    today = datetime.now(BERLIN).date()
    response = await person.hour_slip(DAY, today)
    assert response.status_code == 400
    assert "ended" in response.json()["error"]["message"]


async def test_more_than_thirty_days_is_refused(person: Person):
    response = await person.hour_slip(DAY - timedelta(days=30), DAY)
    assert response.status_code == 400


async def test_a_server_without_an_hour_slip_key_issues_none(store: Store):
    app = build(store)
    _, token, _ = await sign_up(app, store)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://t") as c:
        response = await c.post("/v1/hour-slips", headers={"Authorization": f"Bearer {token}"},
                                json={"from": DAY.isoformat(), "to": DAY.isoformat(),
                                      "timeZone": "Europe/Berlin"})
    assert response.status_code == 503


# MARK: Checking


async def test_the_check_page_confirms_a_genuine_hour_slip(person: Person):
    url = (await person.hour_slip(DAY, NEXT)).json()["url"]
    page = await person.client.get(url.removeprefix("https://slips.test"))
    assert page.status_code == 200
    assert "record still matches" in page.text
    assert person.email in page.text, "the page shows the full address"
    assert "7h 00m" in page.text


async def test_an_altered_hour_slip_is_refused(person: Person):
    url = (await person.hour_slip(DAY, NEXT)).json()["url"]
    token = url.rsplit("/", 1)[1]
    header, payload, signature = token.split(".")
    # Claim an extra hour: re-encode the payload, keep the old signature.
    raw = base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4))
    forged = raw.replace(b'"claimed":25200000', b'"claimed":28800000')
    assert forged != raw
    tampered = base64.urlsafe_b64encode(forged).decode().rstrip("=")
    page = await person.client.get(f"/slip/{header}.{tampered}.{signature}")
    assert page.status_code == 404
    assert "not a valid Deylee hour slip" in page.text


async def test_a_login_token_is_not_a_hour_slip(person: Person):
    page = await person.client.get(f"/slip/{person.token}")
    assert page.status_code == 404


# MARK: Day windows


def test_a_local_day_is_bounded_by_calendar_midnights():
    start, end = _day_window(date(2026, 3, 29), BERLIN)   # clocks go forward: 23 hours
    assert end - start == 23 * 60 * MIN
    start, end = _day_window(date(2026, 10, 25), BERLIN)  # clocks go back: 25 hours
    assert end - start == 25 * 60 * MIN


async def test_compacting_the_beats_into_spans_changes_nothing(person: Person, owner: Store):
    """After 30 days raw beats become spans. An hour slip issued before and one issued
    after must agree, or a slip would stop matching its record a month after it was made.

    Compacted as of a `now` just past the 30-day line for NEXT, so only beats up to then
    move — this account's, and nothing another suite recorded today."""
    before = (await person.hour_slip(DAY, NEXT)).json()
    later = datetime.combine(NEXT + timedelta(days=31), datetime.min.time(), BERLIN)
    async with owner.without_tenant() as connection:
        await connection.fetchrow(
            "SELECT * FROM public.compact_witness_beats(30, 90, $1)",
            int(later.timestamp() * 1000),
        )
        raw_left = await connection.fetchval(
            "SELECT count(*) FROM public.witness_beats WHERE user_id = $1", person.user
        )
    assert raw_left == 0, "the beats under test must actually have been compacted"

    after = (await person.hour_slip(DAY, NEXT)).json()
    assert [d["witnessedMs"] for d in after["days"]] == [d["witnessedMs"] for d in before["days"]]

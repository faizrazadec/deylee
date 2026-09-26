"""Past days are locked, by the server's clock — through the route a client actually uses.

What must hold: a finished segment on a locked day cannot have its times, type or day
changed, and cannot be deleted; the refusal is `locked` and carries the server's copy so
the client can put it back. What must keep working, or honest time is lost: a note edit,
closing or discarding an open segment, today's edits, and a segment the server has never
seen (offline work synced late).

The server's clock cannot be moved from a test, so dates are chosen relative to now in
ways that do not depend on the time of day. The lock instant itself — midnight in the
zone plus two hours, on a 23-hour day too — is checked against zoneinfo's arithmetic.

Connected as the restricted role, like the API; a fresh account per test, so leftover
segments from an earlier run can never overlap this one's.
"""

import logging
import time
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
from fastapi import FastAPI

from deylee_api.app import create_app
from deylee_api.db import Store
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.tokens import TokenService

pytestmark = requires_db
LOGGER = logging.getLogger("day-lock-test")
HOUR_MS = 3_600_000
DAY_MS = 24 * HOUR_MS


def now_ms() -> int:
    return int(time.time() * 1000)


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    assert TEST_DB_URL is not None
    store = Store(TEST_DB_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await store.start()
    try:
        yield store
    finally:
        await store.close()


@pytest.fixture
async def app(store: Store) -> FastAPI:
    config = load_env(valid_env())
    return create_app(
        config=config,
        store=store,
        tokens=TokenService(config),
        mailer=Mailer(
            api_key=config.resend_api_key, sender=config.resend_from,
            template_id=config.resend_otp_template_id, logger=LOGGER,
        ),
        limiter=RateLimiter(),
        logger=LOGGER,
        assert_rls=False,
    )


class Device:
    """One signed-in client: pushes changes and reads back what the server said."""

    def __init__(self, client: httpx.AsyncClient, token: str, user: UUID) -> None:
        self.client = client
        self.token = token
        self.user = user
        self.clock = now_ms()

    def tick(self) -> int:
        """A strictly later `updatedAt` for every push, so last-write-wins lets it in."""
        self.clock = max(self.clock + 1, now_ms())
        return self.clock

    async def push(self, *changes: dict, zone: str | None = "UTC") -> dict:
        body = {"protocolVersion": 1, "cursor": 0, "changes": list(changes)}
        if zone is not None:
            body["timeZone"] = zone
        response = await self.client.post(
            "/v1/sync", json=body, headers={"Authorization": f"Bearer {self.token}"}
        )
        assert response.status_code == 200, response.text
        return response.json()

    def segment(self, segment_id: str, day: str, start: int, end: int | None, **extra) -> dict:
        row = {"id": segment_id, "dayDate": day, "type": "work", "startedAt": start,
               "updatedAt": self.tick(), **extra}
        if end is not None:
            row["endedAt"] = end
        return {"table": "segments", "op": "upsert", "row": row}

    def tombstone(self, segment_id: str) -> dict:
        return {"table": "segments", "op": "delete",
                "row": {"id": segment_id, "updatedAt": self.tick()}}


@pytest.fixture
async def device(app: FastAPI, store: Store) -> AsyncIterator[Device]:
    async with store.without_tenant() as connection:
        subject = f"day-lock-{uuid4()}"
        user: UUID = await connection.fetchval(
            "SELECT id FROM public.auth_sign_in_with_google($1, $2, true, 'Probe', 'UTC')",
            subject, f"{subject}@lock.invalid",
        )
    token = await app.state.tokens.issue_access_token(user, uuid4())
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield Device(client, token, user)


def result(response: dict, segment_id: str) -> dict:
    return next(r for r in response["results"] if r["id"] == segment_id)


def utc_day(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000, UTC).strftime("%Y-%m-%d")


# MARK: Locked


async def test_a_locked_day_refuses_new_times_and_hands_back_the_server_copy(device: Device):
    start = now_ms() - 5 * DAY_MS
    day = utc_day(start)
    seg = str(uuid4())
    # Accepted though the day is long over: the server has never seen it — offline work.
    first = await device.push(device.segment(seg, day, start, start + HOUR_MS))
    assert result(first, seg)["status"] == "applied"

    moved = await device.push(device.segment(seg, day, start, start + 2 * HOUR_MS))
    refused = result(moved, seg)
    assert (refused["status"], refused["code"]) == ("rejected", "locked")
    winner = next(c for c in moved["changes"] if c["row"]["id"] == seg)
    assert winner["row"]["endedAt"] == start + HOUR_MS, "the server's copy, not the edit"


async def test_a_locked_day_refuses_a_delete_and_a_change_of_type(device: Device):
    start = now_ms() - 4 * DAY_MS
    day = utc_day(start)
    seg = str(uuid4())
    await device.push(device.segment(seg, day, start, start + HOUR_MS))

    deleted = await device.push(device.tombstone(seg))
    assert result(deleted, seg)["code"] == "locked"
    retyped = await device.push(device.segment(seg, day, start, start + HOUR_MS, type="break"))
    assert result(retyped, seg)["code"] == "locked"


async def test_a_segment_cannot_be_moved_onto_a_locked_day(device: Device):
    start = now_ms() - 3 * HOUR_MS
    today = utc_day(now_ms())
    seg = str(uuid4())
    await device.push(device.segment(seg, today, start, start + HOUR_MS))

    old_day = utc_day(now_ms() - 6 * DAY_MS)
    moved = await device.push(device.segment(seg, old_day, start, start + HOUR_MS))
    assert result(moved, seg)["code"] == "locked"


async def test_an_open_segment_is_refused_on_a_locked_day(device: Device):
    start = now_ms() - 5 * DAY_MS
    seg = str(uuid4())
    response = await device.push(device.segment(seg, utc_day(start), start, None))
    assert result(response, seg)["code"] == "locked"


# MARK: Still allowed


async def test_a_note_can_still_be_edited_on_a_locked_day(device: Device):
    start = now_ms() - 5 * DAY_MS
    day = utc_day(start)
    seg = str(uuid4())
    await device.push(device.segment(seg, day, start, start + HOUR_MS))

    noted = await device.push(device.segment(seg, day, start, start + HOUR_MS, note="standup"))
    assert result(noted, seg)["status"] == "applied"


async def test_today_can_be_edited_freely(device: Device):
    start = now_ms() - 3 * HOUR_MS
    today = utc_day(now_ms())
    seg = str(uuid4())
    await device.push(device.segment(seg, today, start, start + HOUR_MS))

    moved = await device.push(device.segment(seg, today, start, start + 2 * HOUR_MS))
    assert result(moved, seg)["status"] == "applied"
    deleted = await device.push(device.tombstone(seg))
    assert result(deleted, seg)["status"] == "applied"


async def test_the_zone_the_client_sends_decides_when_its_day_ends(device: Device):
    """One date, two answers. In UTC+14 the day `day` locked at 12:00 UTC that day; in
    UTC-12 it locks at 14:00 UTC the next. Whatever the time now, `day` is chosen to sit
    between the two, so only the zone can decide."""
    now = now_ms()
    now_utc = datetime.fromtimestamp(now / 1000, UTC)
    day = utc_day(now if now_utc.hour >= 12 else now - DAY_MS)
    start = now - 3 * HOUR_MS
    seg = str(uuid4())
    await device.push(device.segment(seg, day, start, start + HOUR_MS))

    east = await device.push(
        device.segment(seg, day, start, start + 2 * HOUR_MS), zone="Etc/GMT-14"
    )
    assert result(east, seg)["code"] == "locked", "UTC+14: that day is over"
    west = await device.push(
        device.segment(seg, day, start, start + 2 * HOUR_MS), zone="Etc/GMT+12"
    )
    assert result(west, seg)["status"] == "applied", "UTC-12: that day is still running"


async def test_an_unknown_zone_is_ignored_rather_than_failing_the_push(device: Device):
    start = now_ms() - 3 * HOUR_MS
    seg = str(uuid4())
    response = await device.push(
        device.segment(seg, utc_day(now_ms()), start, start + HOUR_MS), zone="Mars/Olympus"
    )
    assert result(response, seg)["status"] == "applied"


# MARK: The lock instant


@pytest.mark.parametrize(
    ("zone", "day"),
    [
        ("Europe/Berlin", date(2026, 3, 28)),   # the next midnight follows a normal day
        ("Europe/Berlin", date(2026, 3, 29)),   # a 23-hour day
        ("Europe/Berlin", date(2026, 10, 25)),  # a 25-hour day
        ("Asia/Karachi", date(2026, 9, 26)),
        ("America/Santiago", date(2026, 9, 5)),  # the next midnight does not exist
    ],
)
async def test_a_day_locks_two_hours_after_its_midnight(store: Store, zone: str, day: date):
    tz = ZoneInfo(zone)
    # From calendar components in the zone: never the day's start plus 86,400,000 ms.
    midnight = datetime.combine(day + timedelta(days=1), datetime.min.time(), tz)
    # A midnight that does not exist is resolved forwards, as Postgres does.
    midnight = midnight.astimezone(UTC).astimezone(tz)
    expected = int((midnight + timedelta(hours=2)).timestamp() * 1000)

    async with store.without_tenant() as connection:
        await connection.execute("SELECT set_config('app.time_zone', $1, true)", zone)
        got = await connection.fetchval(
            "SELECT public.day_lock_at($1, $2)", uuid4(), day.isoformat()
        )
    assert got == expected


# MARK: Open segments already on a locked day


async def plant_open_segment(user: UUID, day: str, start: int) -> str:
    """An open segment filed on `day`, as the owner with triggers off — standing in for one
    filed while the day was still running. No client can push one onto a locked day."""
    assert TEST_DB_OWNER_URL is not None
    seg = uuid4()
    owner = Store(TEST_DB_OWNER_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await owner.start()
    try:
        async with owner.without_tenant() as connection:
            await connection.execute("SET LOCAL session_replication_role = replica")
            await connection.execute(
                "INSERT INTO public.segments (id, user_id, day_date, type, started_at, "
                "created_at, updated_at, seq) "
                "VALUES ($1, $2, $3, 'work', $4, $4, $4, nextval('public.sync_seq'))",
                seg, user, day, start,
            )
    finally:
        await owner.close()
    return str(seg)


@requires_owner_db
async def test_an_open_segment_on_a_locked_day_can_still_be_closed(device: Device):
    """The timer's move when a laptop slept across midnight and woke the next day."""
    start = now_ms() - 5 * DAY_MS
    day = utc_day(start)
    seg = await plant_open_segment(device.user, day, start)

    closing = await device.push(device.segment(seg, day, start, start + HOUR_MS))
    assert result(closing, seg)["status"] == "applied"


@requires_owner_db
async def test_an_open_segment_on_a_locked_day_can_still_be_discarded(device: Device):
    """Crash recovery's "discard": an open segment holds no recorded hours."""
    start = now_ms() - 5 * DAY_MS
    seg = await plant_open_segment(device.user, utc_day(start), start)

    discarding = await device.push(device.tombstone(seg))
    assert result(discarding, seg)["status"] == "applied"

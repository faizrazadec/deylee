"""Witness compaction: beats age into spans after 30 days and daily totals after 90.

The property that matters is that `witnessed_time` reports the same numbers before and
after. Compaction deletes the raw beats, so a mistake here is not a wrong answer that can
be recomputed later — it is evidence gone. The awkward cases are the ones planted below:
a gap over 45 seconds (capped, and it breaks a span), a run crossing UTC midnight (the
gap belongs to the later beat's day), and a run crossing the 30-day line (the first raw
beat left behind must still measure back to the last compacted one).

Read and run as the owner: `deylee_api` holds no grant on any of these tables, which the
last test checks. Everything is planted in 2001 and compacted as of a `now` in 2001, so
the beats every other suite records today are newer than any cutoff and never move.
"""

import logging
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from uuid import UUID

import pytest
from conftest import TEST_DB_OWNER_URL, requires_owner_db

from deylee_api.db import Store

pytestmark = requires_owner_db

MIDNIGHT = datetime(2001, 6, 1, tzinfo=UTC)
NOW = MIDNIGHT + timedelta(hours=12)


def ms(moment: datetime) -> int:
    return int(moment.timestamp() * 1000)


def day(days_before: int, hour: int = 0, minute: int = 0, second: int = 0) -> datetime:
    """An instant on the UTC day `days_before` NOW's, from calendar arithmetic."""
    return MIDNIGHT - timedelta(days=days_before) + timedelta(
        hours=hour, minutes=minute, seconds=second
    )


def run(start: datetime, count: int, every: int) -> list[datetime]:
    return [start + timedelta(seconds=every * i) for i in range(count)]


BEATS = [
    # 100 days back: 20 beats 30 s apart, a 10-minute gap, then 5 more.
    *run(day(100, 9), 20, 30),
    *run(day(100, 9, 20), 5, 30),
    # 95/94 days back, across midnight.
    *run(day(95, 23, 59), 4, 30),
    # 60 days back: 40 s apart (under the cap), then a 50 s gap (over it).
    *run(day(60, 10), 10, 40),
    *run(day(60, 10, 6, 50), 3, 40),
    # Across the 30-day line: the 31-day beat compacts, the 30-day beats stay raw.
    day(31, 23, 59, 30),
    *run(day(30), 2, 30),
    # 5 days back: raw throughout.
    *run(day(5, 14), 6, 30),
]


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    assert TEST_DB_OWNER_URL is not None
    store = Store(
        TEST_DB_OWNER_URL, tls=False, ca_certificate_path=None,
        logger=logging.getLogger("witness-compaction-test"),
    )
    await store.start()
    try:
        yield store
    finally:
        await store.close()


@pytest.fixture
async def user(store: Store) -> UUID:
    """One account, emptied of witness rows and planted with BEATS."""
    async with store.without_tenant() as connection:
        user_id = await connection.fetchval(
            "SELECT id FROM public.auth_sign_in_with_google("
            "'witness-compaction-test', 'compaction@witness.invalid', true, 'Probe', 'UTC')"
        )
        for table in ("witness_beats", "witness_spans", "witness_days"):
            await connection.execute(f"DELETE FROM public.{table} WHERE user_id = $1", user_id)
        await connection.executemany(
            "INSERT INTO public.witness_beats (user_id, beat_at) VALUES ($1, $2)",
            [(user_id, ms(beat)) for beat in BEATS],
        )
    return user_id


async def report(store: Store, user_id: UUID) -> dict[str, int]:
    async with store.without_tenant() as connection:
        rows = await connection.fetch(
            "SELECT beat_date, witnessed_ms FROM public.witnessed_time WHERE user_id = $1",
            user_id,
        )
    return {row["beat_date"]: int(row["witnessed_ms"]) for row in rows}


async def compact(store: Store) -> tuple[int, int]:
    async with store.without_tenant() as connection:
        row = await connection.fetchrow(
            "SELECT * FROM public.compact_witness_beats(30, 90, $1)", ms(NOW)
        )
    return row["beats_to_spans"], row["spans_to_days"]


def key(moment: datetime) -> str:
    return moment.strftime("%Y-%m-%d")


async def test_compaction_keeps_the_report_identical(store: Store, user: UUID):
    before = await report(store, user)
    # Checked by hand, so the comparison below is against numbers known to be right: the
    # very first beat vouches for nothing, the 10-minute gap for 45 s.
    assert before[key(day(100))] == (19 * 30 + 45 + 4 * 30) * 1000
    assert before[key(day(95))] == (45 + 30) * 1000, "gap in from day 100, capped"
    assert before[key(day(94))] == (30 + 30) * 1000, "the gap across midnight is day 94's"
    assert before[key(day(60))] == (45 + 9 * 40 + 45 + 2 * 40) * 1000
    assert before[key(day(30))] == (30 + 30) * 1000, "measured back across the 30-day line"

    moved = await compact(store)
    older_than_30_days = sum(1 for beat in BEATS if beat < day(30))
    assert moved[0] == older_than_30_days

    assert await report(store, user) == before, "compaction must not change a single total"

    async with store.without_tenant() as connection:
        raw = await connection.fetchval(
            "SELECT min(beat_at) FROM public.witness_beats WHERE user_id = $1", user
        )
        span_dates = await connection.fetch(
            "SELECT DISTINCT beat_date FROM public.witness_spans WHERE user_id = $1", user
        )
        day_dates = await connection.fetch(
            "SELECT beat_date FROM public.witness_days WHERE user_id = $1", user
        )
    assert raw == ms(day(30)), "only the last 30 days stay raw"
    assert {row["beat_date"] for row in span_dates} == {key(day(60)), key(day(31))}
    assert {row["beat_date"] for row in day_dates} == {key(day(100)), key(day(95)), key(day(94))}


async def test_a_second_run_moves_nothing(store: Store, user: UUID):
    await compact(store)
    after_first = await report(store, user)
    assert await compact(store) == (0, 0)
    assert await report(store, user) == after_first


async def test_the_api_role_cannot_reach_any_of_it(store: Store, user: UUID):
    async with store.without_tenant() as connection:
        for table in ("witness_beats", "witness_spans", "witness_days"):
            for privilege in ("SELECT", "INSERT", "UPDATE", "DELETE"):
                assert not await connection.fetchval(
                    "SELECT has_table_privilege('deylee_api', $1, $2)",
                    f"public.{table}", privilege,
                ), f"deylee_api must hold no {privilege} on {table}"
        assert not await connection.fetchval(
            "SELECT has_function_privilege('deylee_api', "
            "'public.compact_witness_beats(integer, integer, bigint)', 'EXECUTE')"
        )

"""One customer cannot see another's hours.

The property the whole product rests on, and the one nothing but a database can prove:
row-level security is the layer under test, and a mock would only prove the mock.

Set `DEYLEE_TEST_DB_URL` to run these. `./scripts/dev-db.sh` builds exactly the right
thing — the production schema in a throwaway container — and prints the URL:

    DEYLEE_TEST_DB_URL='postgresql://deylee_api_user:devpassword@127.0.0.1:5433/postgres' \
      ./scripts/test-server.sh

Skipped when it is unset, so the suite still runs with no Docker. That is a real gap and
not a comfortable one: unset the variable and the guarantee goes untested exactly as it
was before. Point CI at a container and it stops being optional.

**The URL must be the restricted login, not the owner.** Connecting as `postgres` makes
every one of these pass while proving nothing, because policies do not apply to a
superuser — which is the misconfiguration the boot check exists to refuse.
`test_role_cannot_bypass_policies` runs first and fails loudly rather than letting the
rest pass hollow.

Serialized, and pytest gives that for free: one process, one test at a time, in the order
written. It matters here because these share two fixed accounts and the cleanup
tombstones every live day belonging to them — run two at once and one test's cleanup
removes the row another is still asserting on, which reads as a tenancy failure and is
not one. If a parallel runner is ever added, this module and `test_sweep` have to stay on
one worker.
"""

import logging
from collections.abc import AsyncIterator
from uuid import UUID, uuid4

import pytest
from conftest import TEST_DB_URL, requires_db

from deylee_api.db import Store

pytestmark = requires_db


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    """A live pool against DEYLEE_TEST_DB_URL, shut down with the test."""
    assert TEST_DB_URL is not None  # guaranteed by requires_db
    store = Store(
        TEST_DB_URL, tls=False, ca_certificate_path=None, logger=logging.getLogger("tenancy-test")
    )
    await store.start()
    try:
        yield store
    finally:
        await store.close()


async def seed_two_users(store: Store) -> tuple[UUID, UUID]:
    """Two accounts, through the same SECURITY DEFINER function the Google route calls.

    The restricted role cannot write `app_users` directly — that is what makes it
    restricted — so seeding any other way would need a privileged connection and would
    prove less.

    Fixed Google subjects, so a run reuses the same two accounts instead of leaving a new
    pair behind every time.
    """
    ids: list[UUID] = []
    for subject in ("tenancy-test-a", "tenancy-test-b"):
        async with store.without_tenant() as connection:
            ids.append(
                await connection.fetchval(
                    "SELECT id FROM public.auth_sign_in_with_google($1, $2, true, 'Probe', 'UTC')",
                    subject,
                    f"{subject}@tenancy.invalid",
                )
            )
    await remove_days(store, ids)
    return ids[0], ids[1]


async def remove_days(store: Store, ids: list[UUID]) -> None:
    """Tombstoned rather than deleted, because `deylee_api` holds no DELETE grant on these
    tables — the app only ever tombstones, and the test is bound by the same permissions it
    is testing. `days_one_live_row_per_date` is partial on `deleted_at IS NULL`, so the next
    run can use the same date again."""
    for user_id in ids:
        async with store.with_user(user_id) as connection:
            await connection.execute(
                "UPDATE public.days SET deleted_at = 1 WHERE user_id = $1 AND deleted_at IS NULL",
                user_id,
            )


# Defined first on purpose: without it the rest of the module is theatre, and pytest runs
# them in the order they are written.
async def test_role_cannot_bypass_policies(store: Store):
    """Every assertion below passes trivially when the connection is a role that policies
    do not apply to."""
    await store.assert_not_bypassing_row_level_security()


async def test_neither_user_can_see_the_others_rows(store: Store):
    """The one this whole product rests on."""
    a, b = await seed_two_users(store)
    try:
        for user_id in (a, b):
            async with store.with_user(user_id) as connection:
                await connection.execute(
                    "INSERT INTO public.days (id, user_id, date, target_minutes) "
                    "VALUES ($1, $2, '2026-03-01', 480)",
                    uuid4(),
                    user_id,
                )

        for mine, theirs in ((a, b), (b, a)):
            async with store.with_user(mine) as connection:
                # Deliberately unfiltered, the way the pull query used to be. What comes
                # back is whatever the database is willing to show this connection, which
                # is exactly the layer under test.
                owners = [
                    row[0] for row in await connection.fetch("SELECT user_id FROM public.days")
                ]
            assert mine in owners, "a user must see their own rows"
            assert theirs not in owners, "and none of anybody else's"
    finally:
        await remove_days(store, [a, b])


async def test_a_user_cannot_tombstone_somebody_elses_row(store: Store):
    """`tombstone` takes a client-supplied id and deletes by primary key. With policies
    inactive, one authenticated user could delete any row in the system by learning a
    uuid — the sharpest edge in the audit."""
    a, b = await seed_two_users(store)
    victim_row = uuid4()
    try:
        async with store.with_user(b) as connection:
            await connection.execute(
                "INSERT INTO public.days (id, user_id, date, target_minutes) "
                "VALUES ($1, $2, '2026-03-02', 480)",
                victim_row,
                b,
            )

        # A knows the id and asks for it by primary key, as the route does.
        async with store.with_user(a) as connection:
            await connection.execute(
                "UPDATE public.days SET deleted_at = 9999 WHERE id = $1", victim_row
            )

        async with store.with_user(b) as connection:
            row = await connection.fetchrow(
                "SELECT deleted_at FROM public.days WHERE id = $1", victim_row
            )
        # A missing row is a failure too, not a pass: the owner must still see it live.
        assert row is not None and row[0] is None, "one user tombstoned another user's row"
    finally:
        await remove_days(store, [a, b])

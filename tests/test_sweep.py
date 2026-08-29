"""The refresh-token sweep, and specifically its grace window.

The window is the only interesting part: too long and the table keeps growing, too short
and `auth_rotate_refresh_token` stops being able to say `replayed` — a stolen token then
reads as `unknown`, indistinguishable from a client sending nonsense, and the theft
signal is gone. Both failures are silent, which is why this exists.

Same database gate as the other server suites; see `test_tenancy`.

Serialized, and pytest gives that for free: one process, one test at a time. It matters
more here than anywhere else, because the sweep deletes by expiry across the whole table
rather than per user — two of these at once delete each other's rows and both report the
wrong count, and a clearing sweep would take any refresh token another database-gated
test was holding. If a parallel runner is ever added, this module and `test_tenancy` have
to stay on one worker.
"""

import logging
import time
from collections.abc import AsyncIterator
from uuid import UUID, uuid4

import pytest
from conftest import TEST_DB_URL, requires_db

from deylee_api.db import Store
from deylee_api.tokens import RefreshToken

pytestmark = requires_db

DAY_MS = 86_400_000


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    """A live pool against DEYLEE_TEST_DB_URL, shut down with the test."""
    assert TEST_DB_URL is not None  # guaranteed by requires_db
    store = Store(
        TEST_DB_URL, tls=False, ca_certificate_path=None, logger=logging.getLogger("sweep-test")
    )
    await store.start()
    try:
        yield store
    finally:
        await store.close()


async def probe_user(store: Store) -> UUID:
    """An account to hang the tokens off, through the one function the restricted role can
    create one with."""
    async with store.without_tenant() as connection:
        return await connection.fetchval(
            "SELECT id FROM public.auth_sign_in_with_google("
            "'sweep-test', 'sweep@sweep.invalid', true, 'Probe', 'UTC')"
        )


async def issue_token(store: Store, user: UUID, *, expires_in_days: int) -> None:
    """Issued through the real function, because `refresh_tokens` has row-level security
    enabled with no policies at all: nothing but a SECURITY DEFINER function may write
    there, which is exactly the shape it should be. A test cannot plant an already-expired
    row, and should not be able to.

    So the boundary is approached from the other side. The sweep deletes rows whose expiry
    is older than `now - grace`; a negative grace moves that cutoff into the future, which
    exercises the same arithmetic on rows the test is allowed to make.
    """
    digest = RefreshToken.digest(RefreshToken.generate())
    expiry = int(time.time() * 1000) + expires_in_days * DAY_MS
    async with store.without_tenant() as connection:
        await connection.execute(
            "SELECT public.auth_issue_refresh_token($1, $2, $3, $4, $5)",
            user,
            uuid4(),
            digest,
            uuid4(),
            expiry,
        )


async def sweep(store: Store, *, grace_days: int) -> int:
    async with store.without_tenant() as connection:
        return await connection.fetchval(
            "SELECT public.auth_sweep_expired_refresh_tokens($1)", grace_days
        )


async def test_sweeps_only_what_is_past_the_cutoff(store: Store):
    """The cutoff, and that it is a cutoff rather than a wipe."""
    user = await probe_user(store)
    # The count it returns is the only observable: refresh_tokens has RLS on with no
    # policies, so the restricted role cannot read the table either — which is the correct
    # shape, and means the sweep reports its own work.
    await sweep(store, grace_days=-3650)  # clear anything left behind

    await issue_token(store, user, expires_in_days=10)
    await issue_token(store, user, expires_in_days=90)

    # Cutoff at now + 30 days: the token expiring in 10 is behind it, the one expiring in
    # 90 is not.
    assert await sweep(store, grace_days=-30) == 1, "only the row past the cutoff"
    # And the survivor really did survive, rather than never having been there.
    assert await sweep(store, grace_days=-3650) == 1, "the 90-day row was kept"


async def test_the_default_window_leaves_live_tokens_alone(store: Store):
    """The default window is what actually runs on the schedule, and it must not touch a
    live token. Sweeping at the default with only live rows present has to be a no-op —
    the failure this guards against is a sweep that logs people out."""
    user = await probe_user(store)
    await sweep(store, grace_days=-3650)

    await issue_token(store, user, expires_in_days=90)

    assert await sweep(store, grace_days=30) == 0, (
        "the scheduled sweep must never take a live session"
    )
    assert await sweep(store, grace_days=-3650) == 1, "it was still there"

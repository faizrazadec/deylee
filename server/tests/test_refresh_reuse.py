"""The refresh-token reuse interval, and above all its edges.

Forgiving a reuse is a relaxation of theft detection, so what matters is less that the
window opens than that it stays shut everywhere else: after it lapses, for a token older
than the one just replaced, and on a session that has been signed out.

Same database gate as the other server suites; see `test_tenancy`.
"""

import asyncio
import logging
import time
from collections.abc import AsyncIterator
from uuid import UUID, uuid4

import pytest
from conftest import TEST_DB_URL, requires_db

from deylee_api.db import Store
from deylee_api.tokens import RefreshToken

pytestmark = requires_db

WINDOW_MS = 10_000


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    assert TEST_DB_URL is not None  # guaranteed by requires_db
    store = Store(
        TEST_DB_URL, tls=False, ca_certificate_path=None, logger=logging.getLogger("reuse-test")
    )
    await store.start()
    try:
        yield store
    finally:
        await store.close()


async def new_session(store: Store) -> tuple[UUID, str]:
    """A fresh session holding one live refresh token, through the real functions — the
    table has RLS on with no policies, so nothing else may write there."""
    token = RefreshToken.generate()
    session = uuid4()
    async with store.without_tenant() as connection:
        user = await connection.fetchval(
            "SELECT id FROM public.auth_sign_in_with_google("
            "'reuse-test', 'reuse@reuse.invalid', true, 'Probe', 'UTC')"
        )
        await connection.execute(
            "SELECT public.auth_issue_refresh_token($1, $2, $3, $4, $5)",
            user,
            session,
            RefreshToken.digest(token),
            uuid4(),
            int(time.time() * 1000) + 86_400_000,
        )
    return session, token


async def rotate(store: Store, token: str, *, window_ms: int = WINDOW_MS) -> tuple[str, str]:
    """Exchange `token`; the outcome, and the successor that was offered for it."""
    successor = RefreshToken.generate()
    async with store.without_tenant() as connection:
        outcome = await connection.fetchval(
            "SELECT outcome FROM public.auth_rotate_refresh_token($1, $2, $3, $4)",
            RefreshToken.digest(token),
            RefreshToken.digest(successor),
            int(time.time() * 1000) + 86_400_000,
            window_ms,
        )
    return outcome, successor


async def test_a_reuse_inside_the_window_is_forgiven(store: Store):
    """The case this exists for: one token exchanged twice at once. Both requests get a
    working successor and neither ends the session."""
    _, first = await new_session(store)

    outcome, winner = await rotate(store, first)
    assert outcome == "rotated"

    outcome, sibling = await rotate(store, first)
    assert outcome == "rotated", "the racing second exchange must not read as theft"

    assert (await rotate(store, winner))[0] == "rotated", "the first successor still works"
    assert (await rotate(store, sibling))[0] == "rotated", "and so does the sibling"


async def test_simultaneous_exchanges_both_succeed(store: Store):
    """Genuinely concurrent, not merely sequential: the row lock is what makes the second
    request see the first one's successor rather than skip the check."""
    _, first = await new_session(store)

    outcomes = await asyncio.gather(rotate(store, first), rotate(store, first))
    assert [outcome for outcome, _ in outcomes] == ["rotated", "rotated"]


async def test_a_zero_window_is_the_old_strict_rule(store: Store):
    """Zero is what an API that predates the window gets by default, so it has to be
    exactly the behaviour that API was written against."""
    _, first = await new_session(store)

    outcome, successor = await rotate(store, first, window_ms=0)
    assert outcome == "rotated"
    assert (await rotate(store, first, window_ms=0))[0] == "replayed"
    assert (await rotate(store, successor, window_ms=0))[0] == "replayed", (
        "the replay revoked the whole chain, successor included"
    )


async def test_a_reuse_after_the_window_is_still_theft(store: Store):
    _, first = await new_session(store)

    outcome, successor = await rotate(store, first, window_ms=50)
    assert outcome == "rotated"
    await asyncio.sleep(0.2)

    assert (await rotate(store, first, window_ms=50))[0] == "replayed"
    assert (await rotate(store, successor))[0] == "replayed", "and the chain went with it"


async def test_only_the_token_just_replaced_is_forgiven(store: Store):
    """A token two generations back is not a race; nobody legitimate still holds it."""
    _, first = await new_session(store)

    outcome, second = await rotate(store, first)
    assert outcome == "rotated"
    outcome, third = await rotate(store, second)
    assert outcome == "rotated"

    assert (await rotate(store, first))[0] == "replayed"
    assert (await rotate(store, third))[0] == "replayed", "and the chain went with it"


async def test_a_signed_out_session_gets_no_window(store: Store):
    """Signing out must end the session at once, not ten seconds later."""
    session, first = await new_session(store)

    outcome, _ = await rotate(store, first)
    assert outcome == "rotated"
    async with store.without_tenant() as connection:
        await connection.execute("SELECT public.auth_revoke_session($1)", session)

    assert (await rotate(store, first))[0] == "replayed"

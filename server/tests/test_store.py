"""The pool settings, which are the difference between a request that fails and a
request that never comes back.

Neither of these can be proved by a test that talks to a database — an unreachable one
is exactly what the defaults handled badly, and a reachable one never exercises the
path. What is worth pinning is the configuration itself, because both values were wrong
by default and silently so.

The tenancy behaviour the store exists for is *not* covered here: row-level security is
the thing under test there, a mock would only prove the mock, and those tests are gated
on ``DEYLEE_TEST_DB_URL``. That gap is real.
"""

import asyncio
import contextlib
import logging
import time

import pytest

from deylee_api.db import (
    DEADLINE_SECONDS,
    Store,
    StoreError,
    StoreTimedOut,
    condemns_connection,
    pool_settings,
)

URL = "postgresql://someone:secret@db.example.invalid:5432/postgres"


# MARK: Pooling


def test_keeps_connections_warm():
    """Zero was the default, so the pool held nothing open and every request after a
    quiet spell paid to build a connection from nothing. On a database across an ocean
    that made the first sign-in of the day the one that stalled."""
    assert pool_settings(URL, tls=False, ca_certificate_path=None).min_size > 0


def test_bounds_one_attempt_well_inside_the_request_deadline():
    """The attempt has to give up while the request still has time to spare, or the pool
    never gets to try a second connection before the deadline takes the whole request
    down."""
    assert (
        pool_settings(URL, tls=False, ca_certificate_path=None).connect_timeout < DEADLINE_SECONDS
    )


def test_leaves_room_for_a_slow_but_honest_request():
    """Long enough for honest work. A sign-in against Tokyo measured about 2.5 seconds,
    most of it bcrypt, so a deadline anywhere near that would refuse requests that were
    going to succeed."""
    assert DEADLINE_SECONDS > 10.0


def test_decodes_a_percent_escaped_password():
    """A password may legitimately contain characters that have to be escaped in a URL,
    and passing the escaped form through fails authentication with a message about the
    password being wrong."""
    settings = pool_settings(
        "postgresql://someone:p%40ss%2Fword@db.example.invalid:5432/postgres",
        tls=False,
        ca_certificate_path=None,
    )
    assert settings.password == "p@ss/word"


def test_refuses_encrypted_but_unverified_tls():
    """TLS with nothing to verify against used to degrade to verification-off and log a
    warning. A warning is not a control: one line in a log on a deploy that otherwise
    succeeds, guarding a failure that is silent by construction. Anything answering on
    that host and port would have received the API's database credentials."""
    with pytest.raises(StoreError):
        pool_settings(URL, tls=True, ca_certificate_path=None)


def test_refuses_a_ca_certificate_that_is_not_there():
    """A path that is not there is caught at boot rather than at the first handshake,
    where it surfaces as a connection failure with nothing pointing at the cause."""
    with pytest.raises(StoreError):
        pool_settings(URL, tls=True, ca_certificate_path="/no/such/ca.crt")


def test_tls_disabled_needs_no_certificate():
    """The escape hatch the fallback was really built for: the local development
    container, where there is no certificate and nothing on the wire to protect."""
    assert pool_settings(URL, tls=False, ca_certificate_path=None).ssl is None


def test_refuses_a_url_that_is_not_postgres():
    with pytest.raises(StoreError):
        pool_settings("not a url at all", tls=False, ca_certificate_path=None)


# MARK: The deadline


class _FakeConnection:
    def __init__(self) -> None:
        self.statements: list[str] = []

    async def execute(self, sql: str, *args: object) -> None:
        self.statements.append(sql)


class _FakePool:
    """Stands in for asyncpg's pool so the deadline can be exercised without dialling.

    ``hang`` is a connection that never opens — the failure the deadline exists for.
    """

    def __init__(self, *, hang: bool = False) -> None:
        self.connection = _FakeConnection()
        self.hang = hang

    @contextlib.asynccontextmanager
    async def acquire(self):
        if self.hang:
            await asyncio.sleep(60)
        yield self.connection


def _idle(*, hang: bool = False, deadline: float = DEADLINE_SECONDS) -> Store:
    """A Store that never dials anywhere. The pool is reached into deliberately: there
    is no seam for one, and inventing an injection point for a test would be the larger
    change."""
    store = Store(URL, tls=False, ca_certificate_path=None, logger=logging.getLogger("test"))
    store.deadline = deadline
    store._pool = _FakePool(hang=hang)
    return store


async def test_a_body_that_returns_commits():
    store = _idle()
    async with store.without_tenant() as connection:
        assert connection is store._pool.connection
    assert store._pool.connection.statements == ["BEGIN", "COMMIT"]


async def test_a_failure_comes_back_as_itself():
    class Deliberate(Exception):
        pass

    store = _idle()
    with pytest.raises(Deliberate):
        async with store.without_tenant():
            raise Deliberate
    assert store._pool.connection.statements == ["BEGIN", "ROLLBACK"]


async def test_refuses_when_the_connection_never_opens():
    """The failure the deadline exists for: the far end is unreachable, the pool retries
    behind the lease, and the request simply stops. Somebody signing in sees a spinner
    that never resolves, which is the one failure a person cannot act on.

    A body that swallowed cancellation outright — the case Swift's task-group version got
    wrong — would still hang here, but that is not reachable through this module: the only
    thing awaited inside the deadline is asyncpg, which honours cancellation.
    """
    store = _idle(hang=True, deadline=0.1)
    started = time.monotonic()
    with pytest.raises(StoreTimedOut):
        async with store.without_tenant():
            pass
    # Well under the pool's own 60-second sleep: proof the answer came from the deadline,
    # not from the body giving up.
    assert time.monotonic() - started < 5.0


async def test_the_deadline_also_bounds_a_hanging_query():
    """Not just opening the connection — a query that never answers is refused too."""
    store = _idle(deadline=0.1)
    with pytest.raises(StoreTimedOut):
        async with store.without_tenant():
            await asyncio.sleep(60)


# MARK: Condemned connections


def test_class_28_costs_the_connection():
    """Class 28 is connection authentication, and the driver closes the connection on any
    error carrying it — a ROLLBACK sent afterwards can hang forever."""
    assert condemns_connection("28P01")
    assert condemns_connection("28000")


def test_ordinary_rejections_do_not():
    """Everything the schema deliberately raises stays rollback-able."""
    for state in ["23505", "23514", "P0001", "P0002", "53300"]:
        assert not condemns_connection(state)


def test_a_missing_state_is_not_a_condemnation():
    """No SQLSTATE means the error never came from the server — a closed channel, a
    decoding failure. The ROLLBACK attempt is preserved there: on a dead channel it fails
    fast rather than hanging, and on a live one it is needed."""
    assert not condemns_connection(None)

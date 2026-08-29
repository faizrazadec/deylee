"""Postgres access, with tenancy attached to the transaction rather than to the query.

Every request that touches a user's rows goes through :meth:`Store.with_user`, which
opens a transaction and sets ``app.user_id`` inside it. The row-level security policies
read that variable, so a query which forgets its ``where user_id = ...`` still returns
nothing rather than everything. The application filters and the database filters, and
both have to fail before one customer sees another's hours.

``set_config(..., true)`` is what makes this safe under pooling: it reverts when the
transaction ends, so a connection handed to the next request cannot still be carrying
the last one's identity.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import ssl
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from urllib.parse import unquote, urlsplit
from uuid import UUID

import asyncpg

# What a client is told when the deadline is hit. Kept here because two layers translate
# this — the auth routes, which swallow everything into an error of their own, and the
# handler behind every other route — and two copies of the sentence would drift.
UNAVAILABLE_MESSAGE = "Deylee could not reach its database. Please try again in a moment."

# How long a request may spend waiting on the database before it is refused. Generous on
# purpose: a sign-in against a database on the far side of the world legitimately takes a
# couple of seconds, and bcrypt is slow by design. This is the bound past which something
# is wrong, not a latency target.
DEADLINE_SECONDS = 15.0

# One attempt to open a connection, bounded — and deliberately shorter than the deadline,
# so a connection that will not open fails while there is still time for the pool to try
# another one.
CONNECT_TIMEOUT_SECONDS = 5.0

# The pool would otherwise keep none open, so a request arriving after any quiet spell
# pays to build a connection from nothing: TCP, TLS and authentication against a database
# that may be on another continent. Keeping a couple warm is what stops the first sign-in
# of the day being the one that stalls.
MINIMUM_CONNECTIONS = 2


class StoreError(Exception):
    """Base for the boot-time and deadline failures the store reports."""


class StoreMalformedURL(StoreError):
    def __init__(self) -> None:
        super().__init__("DEYLEE_DB_URL is not a postgresql:// URL with a host and username.")


class StoreTimedOut(StoreError):
    """The database did not answer inside the deadline.

    A refusal the caller can show, rather than a request that never comes back.
    """

    def __init__(self) -> None:
        super().__init__("The database did not answer in time.")


class StoreUnverifiableTLS(StoreError):
    """TLS is on with nothing to verify the far end against. Refused at boot: an
    encrypted connection to whoever answers is not a secure one."""

    def __init__(self) -> None:
        super().__init__(
            "DEYLEE_DB_TLS is on but DEYLEE_DB_CA_CERT is unset, so the database "
            "connection would be encrypted to whoever answers rather than to your "
            "database. Point it at Supabase's CA certificate — the repository ships one "
            "at server/certs/ and the Dockerfile already sets this. For the local "
            "development container, set DEYLEE_DB_TLS=disable instead."
        )


class StoreMissingCACertificate(StoreError):
    """`DEYLEE_DB_CA_CERT` names a file that is not there."""

    def __init__(self, path: str) -> None:
        super().__init__(f"DEYLEE_DB_CA_CERT points at '{path}', which does not exist.")


class StoreBypassesRowLevelSecurity(StoreError):
    """The connected role skips row-level security, so every tenancy policy in the
    schema is inert. Refused at boot rather than served."""

    def __init__(self, role: str) -> None:
        super().__init__(
            f"DEYLEE_DB_URL connects as '{role}', which bypasses row-level security. "
            "Every tenancy policy would be skipped and one customer's sync would read "
            "another's hours. Point it at the restricted login (deylee_api), not "
            "SUPABASE_DB_URL."
        )


@dataclass(frozen=True, slots=True)
class PoolSettings:
    host: str
    port: int
    user: str
    password: str | None
    database: str
    #: None means TLS off, which reaches asyncpg as ``ssl=False`` — an explicit refusal
    #: to encrypt, not asyncpg's default of "prefer", which would silently accept either.
    ssl: ssl.SSLContext | None
    min_size: int
    connect_timeout: float


def pool_settings(url: str, *, tls: bool, ca_certificate_path: str | None) -> PoolSettings:
    """Parse a ``postgresql://user:password@host:port/database`` URL into pool arguments.

    The username and password are percent-decoded: a generated password can legitimately
    contain characters that must be escaped in a URL, and passing the escaped form
    through would fail authentication with a message about the password being wrong —
    which it technically would be.

    No defaults on the TLS arguments, deliberately. ``ca_certificate_path=None`` used to
    be the quiet way to get an unverified connection; making every caller say what it
    wants is what stops that from being the path of least resistance again.
    """
    parts = urlsplit(url)
    try:
        port = parts.port or 5432
    except ValueError as error:  # a non-numeric port
        raise StoreMalformedURL() from error
    if not parts.hostname or not parts.username:
        raise StoreMalformedURL()

    database = parts.path.removeprefix("/") or "postgres"

    # Always encrypt, never "prefer": silently dropping to an unencrypted connection
    # would put every customer's hours on the wire in the clear.
    #
    # Whether the server is *authenticated* as well as encrypted is a separate question,
    # and on Supabase it needs saying out loud. Its Postgres endpoint presents a
    # certificate signed by Supabase's own CA, not by a publicly-trusted one, so
    # verifying against the system trust store fails — which is why psql connects (its
    # default sslmode encrypts without verifying) while a verifying client does not.
    #
    # Point DEYLEE_DB_CA_CERT at the CA certificate from the Supabase dashboard and the
    # connection is both encrypted and authenticated.
    #
    # There is no fall-back worth having. Encrypted-but-unverified means anything that
    # can answer on that host and port — a hijacked DNS record, a compromised path —
    # receives the API's database credentials and serves back whatever rows it likes.
    # This used to degrade to "verification off" and log a warning, which is not a
    # control: one line in a log on a deploy that otherwise succeeds, guarding a failure
    # that is silent by construction.
    #
    # DEYLEE_DB_TLS=disable is the escape hatch, and it is the honest one — the local
    # development container, where there is no certificate and nothing to protect. The
    # Dockerfile sets the path for every real deployment.
    context: ssl.SSLContext | None = None
    if tls:
        if ca_certificate_path is None:
            raise StoreUnverifiableTLS()
        if not os.path.exists(ca_certificate_path):
            # Checked at boot rather than left to the first handshake, where it surfaces
            # as a connection failure with nothing pointing at the cause.
            raise StoreMissingCACertificate(ca_certificate_path)
        context = ssl.create_default_context(cafile=ca_certificate_path)
        context.check_hostname = True
        context.verify_mode = ssl.CERT_REQUIRED
        # Chain and hostname are still verified against the pinned CA above — that is the
        # control, and it stays. What goes is OpenSSL's *strict* X.509 extension policy,
        # which `create_default_context` turns on by default from Python 3.13 and which
        # Swift's NIOSSL never applied. Supabase's pooler serves a chain that does not
        # satisfy it ("CA cert does not include key usage extension"), so leaving it on
        # refuses every connection to the production database while a local container
        # with TLS disabled looks perfectly healthy — which is exactly how this reached
        # production. Relaxing the extension policy is not the same as trusting anyone:
        # an impostor still has to present a chain signed by that pinned CA.
        context.verify_flags &= ~ssl.VERIFY_X509_STRICT

    return PoolSettings(
        host=parts.hostname,
        port=port,
        user=unquote(parts.username),
        password=unquote(parts.password) if parts.password else parts.password,
        database=database,
        ssl=context,
        min_size=MINIMUM_CONNECTIONS,
        connect_timeout=CONNECT_TIMEOUT_SECONDS,
    )


def condemns_connection(sqlstate: str | None) -> bool:
    """Whether this error has already cost the connection its life.

    A server error in SQLSTATE class 28 — the class Postgres uses for *connection*
    authentication — takes the connection down with it. A ROLLBACK sent afterwards races
    the teardown, and losing that race means a request that hangs forever holding its
    pool lease. The transaction needs no goodbye anyway: the server aborts it when the
    connection drops.

    The schema's own rule is that no function raises class 28 (see the sign_in_error_code
    migration), so this guard is for the codes the schema cannot promise away: a revoked
    role, an expired password, a proxy in front of the database speaking for it.
    """
    return sqlstate is not None and sqlstate.startswith("28")


class Store:
    def __init__(
        self,
        url: str,
        *,
        tls: bool,
        ca_certificate_path: str | None,
        logger: logging.Logger,
    ) -> None:
        self.settings = pool_settings(url, tls=tls, ca_certificate_path=ca_certificate_path)
        self.deadline = DEADLINE_SECONDS
        self.logger = logger
        self._pool: asyncpg.Pool | None = None

    async def start(self) -> None:
        self._pool = await asyncpg.create_pool(
            host=self.settings.host,
            port=self.settings.port,
            user=self.settings.user,
            password=self.settings.password,
            database=self.settings.database,
            ssl=self.settings.ssl if self.settings.ssl is not None else False,
            min_size=self.settings.min_size,
            timeout=self.settings.connect_timeout,
        )

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None

    @asynccontextmanager
    async def _transaction(self) -> AsyncIterator[asyncpg.Connection]:
        """A transaction, refusing rather than hanging when the database does not answer.

        Acquiring from the pool waits with no bound of its own, and the connect timeout
        bounds a single attempt to open a connection rather than the wait for one. So
        when the far end is unreachable the pool retries behind the lease and the request
        simply stops — until the caller gives up. Somebody signing in sees a spinner that
        never resolves, which is the one failure a person cannot act on.

        ``asyncio.timeout`` replaces the stream-race the Swift version needed: asyncpg
        honours cancellation, so the work stops instead of being abandoned to finish on
        its own.

        BEGIN/COMMIT are explicit rather than ``connection.transaction()`` so the class-28
        guard below stays reachable.
        """
        if self._pool is None:
            raise RuntimeError("Store.start() was never awaited")
        try:
            async with asyncio.timeout(self.deadline) as deadline:
                async with self._pool.acquire() as connection:
                    await connection.execute("BEGIN")
                    try:
                        yield connection
                    except BaseException as error:
                        sqlstate = (
                            error.sqlstate if isinstance(error, asyncpg.PostgresError) else None
                        )
                        # Cancellation is skipped for the same reason class 28 is: a
                        # cancelled task cannot await anything, and releasing the lease
                        # resets the connection regardless.
                        if not condemns_connection(sqlstate) and not isinstance(
                            error, asyncio.CancelledError
                        ):
                            # A failed rollback must never replace the real error.
                            with contextlib.suppress(Exception):
                                await connection.execute("ROLLBACK")
                        raise
                    await connection.execute("COMMIT")
        except TimeoutError as error:
            if not deadline.expired():
                raise  # somebody else's timeout, passing through
            self.logger.warning("abandoning a database call at the deadline")
            raise StoreTimedOut() from error

    @asynccontextmanager
    async def with_user(
        self, user_id: UUID, *, lock_for_write: bool = False
    ) -> AsyncIterator[asyncpg.Connection]:
        """A transaction scoped to one user.

        The advisory lock serialises writes per user, which is what makes the sync cursor
        safe: sequence values are handed out when a row is written but transactions commit
        in a different order, so without this a pull can step past a row that has not
        committed yet and never see it again.

        Locking per user rather than globally means two customers still write
        concurrently; only one person's own devices queue behind each other, and they are
        rarely writing at the same instant anyway.
        """
        # Uppercase because that is what Swift's UUID.uuidString produced, and both the
        # lock's hash and app.user_id must match the value the other implementation used.
        identifier = str(user_id).upper()
        async with self._transaction() as connection:
            if lock_for_write:
                await connection.execute(
                    "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", identifier
                )
            # set_config rather than SET LOCAL, because SET takes no parameters and would
            # leave the user id to be pasted into SQL.
            await connection.execute("SELECT set_config('app.user_id', $1, true)", identifier)
            yield connection

    @asynccontextmanager
    async def without_tenant(self) -> AsyncIterator[asyncpg.Connection]:
        """A transaction with no tenancy set.

        Sign-in and refresh legitimately run before any user is known, and they touch
        `app_users` and `refresh_tokens`, neither of which a user-scoped connection can
        reach. Everything else must use :meth:`with_user`.
        """
        async with self._transaction() as connection:
            yield connection

    async def assert_not_bypassing_row_level_security(self) -> None:
        """Refuse to serve as a role that row-level security does not apply to.

        Tenancy rests on the policies binding, and they bind only to an ordinary role. A
        superuser, or one holding BYPASSRLS, skips every policy — silently. Nothing else
        would look wrong: the connection succeeds, the health check passes, the log says
        `listening`, and every sync then reads and tombstones every customer's rows.

        The misconfiguration is one character of `.env` away, because `SUPABASE_DB_URL`
        connects as `postgres` and sits directly above `DEYLEE_DB_URL` in the file.
        Checked at boot rather than per request: this cannot change while the process
        runs, and a process that would serve every tenant's data to whoever asks should
        not start at all.
        """
        async with self.without_tenant() as connection:
            row = await connection.fetchrow(
                "SELECT current_user::text, rolsuper, rolbypassrls "
                "FROM pg_roles WHERE rolname = current_user"
            )

        # No matching row means the role is not in pg_roles at all, which should be
        # impossible for the role we are connected as. Unknown is not safe.
        role, is_super, bypasses = (row[0], row[1], row[2]) if row else ("unknown", True, True)
        if is_super or bypasses:
            raise StoreBypassesRowLevelSecurity(role)
        self.logger.info("tenancy enforced as %s", role)

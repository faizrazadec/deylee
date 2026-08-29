"""Fixed-window rate limiting, and the body ceiling, both in memory."""

from __future__ import annotations

import logging
import math
import time

from starlette.requests import Request
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from deylee_api.errors import error_response


class RateLimiter:
    """A fixed-window counter, in memory.

    Rate limiting exists here for a reason that is not brute force, though it stops that
    too. Every password attempt runs bcrypt at cost 12 — a quarter-second of database CPU,
    deliberately, and the same property that makes a stolen hash expensive to crack makes
    an unauthenticated request expensive to serve. A handful of concurrent callers
    saturates Postgres, and sync stops for every paying customer while the one route
    nobody can shed is the way back in.

    Closing the timing channel made that worse rather than better: an unknown address used
    to cost nothing and now costs the same quarter-second as a real one. The two changes
    only make sense together.

    Plain synchronous methods rather than the Swift actor: this runs on one event loop and
    nothing here awaits between reading a window and writing it back, so there is nothing
    to serialise.

    ponytail: fixed window and a single process's memory. Two ceilings, both fine here and
    neither hidden — a burst straddling a window boundary gets up to twice the allowance,
    and a second instance would keep its own counts. Postgres-backed counters or a shared
    cache is the upgrade when this runs more than one replica.
    """

    def __init__(self) -> None:
        # key -> (count, started_at). The clock is monotonic, never wall-clock: a clock
        # change must not hand out a free window.
        self._windows: dict[str, tuple[int, float]] = {}
        # Swept opportunistically rather than on a timer: the map is only ever touched
        # from here, and a request is the only thing that makes it grow.
        self._last_sweep = time.monotonic()

    def seconds_until_allowed(self, key: str, *, limit: int, window: float) -> int | None:
        """None when the caller may proceed. Otherwise the seconds to put in `Retry-After`.

        Reading does not count. `record` is what counts, so a caller can be metered on
        failures alone — someone signing in correctly on four devices is not an attack,
        and charging them for it would lock out the people who did nothing wrong.
        """
        now = time.monotonic()
        self._sweep_if_due(now, window)

        existing = self._windows.get(key)
        if existing is None:
            return None
        count, started_at = existing
        elapsed = now - started_at
        if elapsed >= window or count < limit:
            return None
        # Rounded up, and never below one: a `Retry-After: 0` invites an immediate retry
        # that is certain to be refused again.
        return max(1, math.ceil(window - elapsed))

    def record(self, key: str, *, window: float) -> None:
        """Count one against `key`."""
        now = time.monotonic()
        existing = self._windows.get(key)
        if existing is not None and now - existing[1] < window:
            self._windows[key] = (existing[0] + 1, existing[1])
        else:
            self._windows[key] = (1, now)

    def _sweep_if_due(self, now: float, window: float) -> None:
        if now - self._last_sweep <= window:
            return
        self._last_sweep = now
        self._windows = {
            key: entry for key, entry in self._windows.items() if now - entry[1] < window
        }


def caller_of(request: Request) -> str:
    """Cloudflare's header first, then the standard one's first hop — the left-most entry
    is the original client, everything after it is a proxy.

    The caller is identified by the forwarded header rather than by the socket. The API
    runs behind a tunnel, so the peer address is the tunnel for every request in the world
    and would put everybody in one bucket by accident.

    A request arriving with no forwarded header shares a single bucket. The header is
    trivially forged by anything talking to the process directly, so this is not an
    identity to trust — it is a ceiling on damage, not an authenticator.

    That shared bucket has to be generous for exactly the same reason it exists. If the
    proxy ever stops setting the header, every customer in the world lands in it at once,
    and a limit sized for one person would take the product down far more effectively than
    the attack it was guarding against.
    """
    cloudflare = request.headers.get("CF-Connecting-IP")
    if cloudflare:
        return cloudflare
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        first = forwarded.split(",")[0].strip()
        if first:
            return first
    return "unattributed"


class RateLimitMiddleware:
    """Throttles the auth routes, and only those.

    `/v1/sync` is authenticated and cheap by comparison; the unauthenticated routes are
    where a stranger can spend the server's money. It is in the list anyway because the
    protocol document says it can answer 429 with an authoritative `Retry-After`, and a
    binding contract that describes behaviour the server does not have is how the next
    client author implements a handler for a response that never arrives. The ceiling is
    far above honest traffic — a device syncs every two minutes — so this bounds a runaway
    client rather than metering a real one.
    """

    def __init__(
        self,
        app: ASGIApp,
        *,
        limiter: RateLimiter,
        limit: int,
        window: float,
        logger: logging.Logger,
    ) -> None:
        self.app = app
        self.limiter = limiter
        self.limit = limit
        self.window = window
        self.logger = logger

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        path = scope.get("path", "")
        if scope["type"] != "http" or not (path.startswith("/v1/auth/") or path == "/v1/sync"):
            await self.app(scope, receive, send)
            return

        key = f"ip:{caller_of(Request(scope))}"
        # Every request counts here, not just failures: this bounds the work a source can
        # make the server do, and a successful sign-in costs the same bcrypt as a failed
        # one.
        retry_after = self.limiter.seconds_until_allowed(key, limit=self.limit, window=self.window)
        if retry_after is not None:
            self.logger.warning("rate limited path=%s retryAfter=%d", path, retry_after)
            # Returned rather than raised: Starlette's exception handlers sit inside the
            # middleware stack and would never see it.
            response = error_response(
                429,
                f"Too many attempts. Try again in {retry_after} seconds.",
                {"Retry-After": str(retry_after)},
            )
            await response(scope, receive, send)
            return

        self.limiter.record(key, window=self.window)
        await self.app(scope, receive, send)


class _BodyTooLarge(Exception):
    """Raised out of the wrapped `receive`, caught in the middleware that wrapped it.

    The route reads the body before it answers, so this unwinds before anything has been
    sent and the 413 is still ours to write. It must stay inside Starlette's
    ServerErrorMiddleware, which is where `add_middleware` puts it.
    """


class BodyLimitMiddleware:
    """Refuse a request body over `max_bytes`.

    Hummingbird's 2 MB default was not obviously wrong until you work out what a
    legitimate maximum push weighs. The protocol allows 500 changes and the schema allows
    a 2000-*character* note; characters are not bytes, and 2000 emoji are 8 KB of UTF-8.
    So the largest push a conforming client may send is about 4.2 MB — and it was being
    refused with a 413 it could never get past, because the client re-sends the same 500
    rows every time. A permanent sync stall, from a limit nobody chose.

    8 MB leaves room for that worst case and for the escaping around it, and still bounds
    what one authenticated caller can make the process allocate. Passed in rather than
    inherited: this number now moves when somebody decides it should, not when a
    dependency does.
    """

    def __init__(self, app: ASGIApp, *, max_bytes: int, logger: logging.Logger) -> None:
        self.app = app
        self.max_bytes = max_bytes
        self.logger = logger

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        declared = dict(scope.get("headers", [])).get(b"content-length")
        if declared is not None and declared.isdigit() and int(declared) > self.max_bytes:
            await self._refuse(scope, receive, send)
            return

        # Content-Length is not enough on its own: a client can simply omit it and stream
        # the body in chunks, so the bytes are counted as they arrive too.
        received = 0

        async def counting_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    raise _BodyTooLarge
            return message

        try:
            await self.app(scope, counting_receive, send)
        except _BodyTooLarge:
            await self._refuse(scope, receive, send)

    async def _refuse(self, scope: Scope, receive: Receive, send: Send) -> None:
        self.logger.warning(
            "request body over the limit path=%s maxBytes=%d",
            scope.get("path", ""),
            self.max_bytes,
        )
        response = error_response(
            413, "That request body is too large. Send fewer changes per push."
        )
        await response(scope, receive, send)

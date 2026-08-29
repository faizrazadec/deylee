"""The shape of what goes over the wire, pinned against a shipped client.

docs/SYNC_PROTOCOL.md is binding and the Mac app already speaks it, so these are not
tests of preference. The Mac app decodes `{"error":{"message":…}}` and falls back to
printing the raw body when that fails, so FastAPI's own `{"detail":…}` would surface to a
person as a line of JSON; its 422 for a body it cannot validate is a status the protocol
does not have; and a `"note": null` where Swift's `encodeIfPresent` omitted the key is a
field a client decodes differently.

None of this needs Postgres. The store here is built and never started, which is also how
the health check proves it does not touch the database: anything that reached the pool
would raise and come back as a 500.
"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

import httpx
import pytest
from conftest import load_env, valid_env
from fastapi import FastAPI
from pydantic import BaseModel

from deylee_api.app import MAX_BODY_BYTES, create_app
from deylee_api.db import Store
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.routes.auth import CodeSentResponse, SessionResponse, UserDTO, _user
from deylee_api.routes.sync import ChangeResult, SyncChange, SyncResponse, SyncRow
from deylee_api.tokens import TokenService

LOGGER = logging.getLogger("wire-test")
#: Where the rate limiter files this client, given the header sent below. `caller_of`
#: reads the forwarded header rather than the socket, because the API runs behind a
#: tunnel and the peer address is the tunnel for every request in the world.
CALLER = "203.0.113.7"
FORWARDED = {"X-Forwarded-For": CALLER}


def build_app() -> tuple[FastAPI, RateLimiter]:
    """The app as `__main__` assembles it, with a store that was never started."""
    config = load_env(valid_env())
    store = Store(config.database_url, tls=False, ca_certificate_path=None, logger=LOGGER)
    limiter = RateLimiter()
    app = create_app(
        config=config,
        store=store,
        tokens=TokenService(config),
        mailer=Mailer(
            api_key=config.resend_api_key,
            sender=config.resend_from,
            template_id=config.resend_otp_template_id,
            logger=LOGGER,
        ),
        limiter=limiter,
        logger=LOGGER,
        # The lifespan never runs under ASGITransport, so this only says out loud that
        # the boot check is not what is under test here.
        assert_rls=False,
    )
    return app, limiter


@asynccontextmanager
async def client_for(app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


def assert_envelope(response: httpx.Response, status: int) -> str:
    """Assert the one envelope, and return the sentence inside it."""
    assert response.status_code == status, response.text
    body = response.json()
    assert set(body) == {"error"}, f"extra top-level keys: {body}"
    assert set(body["error"]) == {"message"}, f"extra error keys: {body}"
    message = body["error"]["message"]
    assert isinstance(message, str) and message, f"empty message: {body}"
    return message


# ------------------------------------------------------------------- The envelope


@pytest.mark.parametrize(
    ("method", "path", "payload", "status"),
    [
        # A refusal the route decided on, before anything reaches the database.
        ("POST", "/v1/auth/google", {"idToken": "whatever", "timezone": "UTC"}, 400),
        # A route that trusts a session, with none presented.
        ("POST", "/v1/sync", {"protocolVersion": 1, "cursor": 0, "changes": []}, 401),
        # The router's own refusal, which is the one an ordinary framework leaves in its
        # own format because no handler was ever written for it.
        ("POST", "/v1/auth/nothing-here", {}, 404),
        ("GET", "/health/nope", None, 404),
    ],
)
async def test_every_refusal_arrives_in_the_error_envelope(method, path, payload, status):
    """`{"error":{"message":…}}` or nothing.

    The Mac app decodes exactly this and falls back to the raw body, so a `{"detail":…}`
    from any layer — a route, the validator, the router's 404 — reaches a person as a
    line of JSON they cannot act on.
    """
    app, _ = build_app()
    async with client_for(app) as client:
        response = await client.request(method, path, json=payload)
    assert_envelope(response, status)


async def test_a_validation_failure_is_400_and_never_422():
    """FastAPI answers a body it cannot validate with 422 and its own envelope. Both
    halves are off-contract: the protocol spells an unreadable body 400, and 422 is a
    status no client here has a branch for.

    Exercised through a probe route because every real route parses its own body — which
    is itself the reason the routes do that, and the handler is the safety net for the day
    somebody adds a route the ordinary way.
    """

    class Probe(BaseModel):
        n: int

    app, _ = build_app()

    @app.post("/probe")
    async def probe(body: Probe) -> dict[str, int]:  # pragma: no cover - never reached
        return {"n": body.n}

    async with client_for(app) as client:
        mismatched = await client.post("/probe", json={"n": "not-a-number"})
        missing = await client.post("/probe", json={})

    assert mismatched.status_code != 422
    assert assert_envelope(mismatched, 400) == "Type mismatch for `n` key."
    assert assert_envelope(missing, 400) == "Coding key `n` not found."


async def test_malformed_json_is_400():
    """A body the route cannot decode is the client's fault, not the server's. It used to
    be easy for this to surface as a 500."""
    app, _ = build_app()
    async with client_for(app) as client:
        response = await client.post(
            "/v1/auth/password",
            content=b'{"email":"half',
            headers={"Content-Type": "application/json"},
        )
    assert_envelope(response, 400)


# ------------------------------------------------------------------------ Health


async def test_health_is_ok_and_does_not_touch_the_database():
    """Liveness only.

    A health check that fails when Postgres is briefly unreachable invites an
    orchestrator to kill a process that would otherwise have recovered on its own. The
    store here has no pool at all, so any query would raise and come back as a 500 —
    which is what makes the 200 evidence rather than assertion.
    """
    app, _ = build_app()
    async with client_for(app) as client:
        response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# -------------------------------------------------------------------- Body ceiling


async def _chunks(total: int) -> AsyncIterator[bytes]:
    sent = 0
    while sent < total:
        block = b"x" * min(64 * 1024, total - sent)
        sent += len(block)
        yield block


@pytest.mark.parametrize("declared", [True, False])
async def test_a_body_over_the_ceiling_is_413(declared: bool):
    """Over the limit is a 413 with a sentence naming the fix, whether or not the client
    admits how much it is sending.

    Content-Length is not enough on its own: a client can omit it and stream the body in
    chunks, and a ceiling that only reads the header is one an attacker simply does not
    set.
    """
    oversized = MAX_BODY_BYTES + 64 * 1024
    app, _ = build_app()
    async with client_for(app) as client:
        if declared:
            response = await client.post("/v1/auth/password", content=b"x" * oversized)
        else:
            response = await client.post("/v1/auth/password", content=_chunks(oversized))

    message = assert_envelope(response, 413)
    assert message == "That request body is too large. Send fewer changes per push."


# --------------------------------------------------------------------- Throttling


async def test_the_rate_limiter_covers_the_auth_routes_and_sync_but_not_health():
    """The limiter sits in front of the expensive routes and nowhere else.

    `/v1/auth/*` is where a stranger can spend the server's money — every password attempt
    costs a quarter-second of database CPU by design. `/v1/sync` is in the list because the
    protocol document says it can answer 429, and a binding contract describing behaviour
    the server does not have is how the next client author writes a handler for a response
    that never arrives.

    `/health` must stay out of it: a throttled liveness probe reads to an orchestrator as a
    dead process.

    The 429s here come before authentication, which is the point — a caller with no token
    must not be able to make the server do the work of deciding that.
    """
    app, limiter = build_app()
    for _ in range(600):
        limiter.record(f"ip:{CALLER}", window=60.0)

    async with client_for(app) as client:
        auth = await client.post("/v1/auth/password", json={}, headers=FORWARDED)
        sync = await client.post("/v1/sync", json={}, headers=FORWARDED)
        health = await client.get("/health", headers=FORWARDED)

    for response in (auth, sync):
        assert_envelope(response, 429)
        # The protocol says Retry-After is authoritative, so it has to be there and has to
        # be a number a client can wait for. `Retry-After: 0` invites an immediate retry
        # that is certain to be refused again.
        seconds = response.headers.get("Retry-After")
        assert seconds is not None and seconds.isdigit(), f"unparseable: {seconds!r}"
        assert int(seconds) > 0

    assert health.status_code == 200


# -------------------------------------------------------------- JSON, field by field


def test_a_null_field_is_omitted_rather_than_sent_as_null():
    """Swift's Codable did `encodeIfPresent`, so an absent value never appeared at all.

    The clients decode a missing key and a null differently, so `"note": null` on a segment
    that never had one is a different row from the client's point of view. `endedAt` is the
    sharper case: on a segment it means "still running", which is not the same claim as
    "this key was not sent".
    """
    row_id = UUID("a1b2c3d4-e5f6-4a8b-9c0d-1e2f3a4b5c6d")
    response = SyncResponse(
        protocolVersion=1,
        cursor=12,
        serverTime=1_700_000_000_000,
        hasMore=False,
        results=[ChangeResult(id=str(row_id), status="applied")],
        changes=[
            SyncChange(
                table="segments",
                op="upsert",
                # Built the way `_pull` builds it, from the UUID asyncpg hands back.
                row=SyncRow(
                    id=str(row_id),
                    dayDate="2026-03-01",
                    type="work",
                    startedAt=1_700_000_000_000,
                    endedAt=None,
                    note=None,
                    createdAt=1_700_000_000_000,
                    updatedAt=1_700_000_000_000,
                    deletedAt=None,
                    seq=12,
                ),
            )
        ],
    )

    dumped = response.model_dump(exclude_none=True)
    row = dumped["changes"][0]["row"]
    for absent in ("endedAt", "note", "deletedAt", "date", "targetMinutes"):
        assert absent not in row, f"{absent} was sent as null"
    # A result that applied cleanly carries no code and no message.
    assert set(dumped["results"][0]) == {"id", "status"}

    # Lower case, because a client upserts by this string into a case-SENSITIVE text
    # index. Echoing an id back in the other case inserts a duplicate of every row the
    # client already held.
    assert row["id"] == "a1b2c3d4-e5f6-4a8b-9c0d-1e2f3a4b5c6d"


def test_user_ids_are_lower_case_on_the_wire_and_upper_inside_a_token():
    """The two cases are not a style choice and cannot be unified.

    Inside an access token, Swift wrote UUIDs with `UUID.uuidString`, which is upper case;
    tokens minted by either implementation have to verify against the other, so that shape
    is frozen. On the wire the clients' SQLite stores use lower case. A single convention
    would break one of the two.
    """
    user_id = UUID("A1B2C3D4-E5F6-4A8B-9C0D-1E2F3A4B5C6D")
    assert _user(user_id, "a@example.test", None, "UTC").id == str(user_id).lower()


def test_response_field_names_are_camel_case():
    """The names are the contract. A rename to snake_case reads as a missing field to
    every shipped client rather than as an error."""
    assert set(CodeSentResponse.model_fields) == {"expiresIn", "resendIn"}
    assert set(SessionResponse.model_fields) == {
        "accessToken",
        "refreshToken",
        "expiresIn",
        "user",
    }
    assert set(UserDTO.model_fields) == {"id", "email", "displayName", "timezone"}
    assert set(ChangeResult.model_fields) == {"id", "status", "code", "message"}
    assert set(SyncResponse.model_fields) == {
        "protocolVersion",
        "cursor",
        "serverTime",
        "hasMore",
        "results",
        "changes",
    }


def test_a_session_response_omits_a_missing_display_name():
    """`displayName` is the one optional in a session, and a Google account without a
    name is ordinary rather than exceptional."""
    dumped = SessionResponse(
        accessToken="a",
        refreshToken="b",
        expiresIn=3600,
        user=UserDTO(id="a1b2c3d4-e5f6-4a8b-9c0d-1e2f3a4b5c6d", email="a@b.test", timezone="UTC"),
    ).model_dump(exclude_none=True)
    assert "displayName" not in dumped["user"]

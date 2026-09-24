"""Sign-in, sign-up, refresh and sign-out.

Every database call here goes through a SECURITY DEFINER function rather than a table.
Authentication cannot be tenant-scoped — it is what establishes the tenant — so the API's
ordinary row-level-security-bound connection cannot read or write these rows at all. The
functions are the enumerated exceptions, and the account-linking rules live inside them,
where both sign-in routes share one copy.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Iterator
from contextlib import contextmanager
from uuid import UUID, uuid4

import asyncpg
from fastapi import APIRouter, Request
from pydantic import BaseModel

from deylee_api.config import Config
from deylee_api.db import UNAVAILABLE_MESSAGE, Store, StoreTimedOut
from deylee_api.errors import APIError
from deylee_api.mail import Mailer, generate_signup_code
from deylee_api.ratelimit import RateLimiter
from deylee_api.tokens import RefreshToken, TokenError, TokenService

router = APIRouter()


# ----------------------------------------------------------------- Wire types


class GoogleSignInRequest(BaseModel):
    #: The ID token the client obtained from Google. Proof of identity, never a session —
    #: it expires in about an hour and is used exactly once, here.
    idToken: str
    deviceId: UUID | None = None
    #: IANA name, e.g. "Europe/Berlin". Day boundaries are local, so a report spanning two
    #: countries is wrong without it.
    timezone: str | None = None
    #: What the client put in its authorization request. The ID token must echo it, or it
    #: was minted for some other sign-in.
    nonce: str | None = None


class PasswordRequest(BaseModel):
    email: str
    password: str
    displayName: str | None = None
    deviceId: UUID | None = None
    timezone: str | None = None


class SetPasswordRequest(BaseModel):
    password: str


class SignupCodeRequest(BaseModel):
    """Ask for a sign-up code. Carries the password, because the account is built from
    this request once the code comes back — there is no second chance to collect it."""

    email: str
    password: str
    displayName: str | None = None
    timezone: str | None = None


class VerifyCodeRequest(BaseModel):
    email: str
    code: str
    deviceId: UUID | None = None
    timezone: str | None = None


class RefreshRequest(BaseModel):
    refreshToken: str


class CodeSentResponse(BaseModel):
    """What the client needs to draw the code screen without inventing its own copy of the
    server's constants."""

    #: Seconds until the code stops working.
    expiresIn: int
    #: Seconds before another code may be requested.
    resendIn: int


class UserDTO(BaseModel):
    id: str
    email: str
    displayName: str | None = None
    timezone: str


class SessionResponse(BaseModel):
    accessToken: str
    refreshToken: str
    #: Seconds, so a client can schedule its own refresh rather than waiting for a 401 and
    #: retrying — which would make every expiry cost a wasted round trip.
    expiresIn: int
    user: UserDTO


# -------------------------------------------------------------------- Routes


@router.post("/v1/auth/google", response_model=SessionResponse, response_model_exclude_none=True)
async def sign_in_with_google(request: Request) -> SessionResponse:
    body = await _decode(request, GoogleSignInRequest)

    # Required, not merely checked when present. The body is the caller's to write, so an
    # optional nonce is one an attacker simply omits — and the binding would then hold only
    # for the clients that were never the threat. Nothing has shipped without it, so there
    # is no older client to accommodate.
    if not body.nonce:
        raise APIError(400, "A nonce is required.")

    tokens: TokenService = request.app.state.tokens
    try:
        claims = await tokens.verify_google_id_token(body.idToken, body.nonce)
    except TokenError as error:
        raise APIError(401, str(error)) from error
    if claims.email is None:
        raise APIError(401, "Google returned no email address.")

    # Adopting an existing account with this address is safe here and only here: Google
    # asserts it verified the mailbox, so whoever holds this token controls it. Sign-up
    # with a password deliberately refuses the reverse.
    user = await _user_returned_by(
        request,
        """
        SELECT id, email, display_name, timezone
        FROM public.auth_sign_in_with_google($1, $2, $3, $4, $5)
        """,
        claims.sub,
        claims.email,
        claims.email_verified or False,
        claims.name,
        body.timezone,
    )
    return await _issue_session(request, user, body.deviceId)


@router.post("/v1/auth/signup", response_model=CodeSentResponse)
async def request_signup_code(request: Request) -> CodeSentResponse:
    """Step one of sign-up: park the request and mail a code.

    No account exists when this returns. That is the point — an account nobody has verified
    is exactly what let somebody register a stranger's address and keep a password on the
    account the real owner was later handed by Google.

    The code is generated here and never stored in the clear. The database keeps only a
    bcrypt digest of it, so this process is the last place the digits exist outside the mail
    itself.
    """
    config: Config = request.app.state.config
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    mailer: Mailer = request.app.state.mailer

    body = await _decode(request, SignupCodeRequest)
    code = generate_signup_code()

    # The row is written first. Sending mail for a request the database refused — a taken
    # address, a password too short, a resend inside the cooldown — would hand an attacker a
    # way to post mail to any inbox they can name.
    with _translating(logger):
        async with store.without_tenant() as connection:
            await connection.execute(
                """
                SELECT public.auth_request_signup_code($1, $2, $3, $4, $5, $6, $7)
                """,
                body.email,
                body.password,
                body.displayName,
                body.timezone,
                code,
                config.signup_code_ttl,
                config.signup_code_resend_cooldown,
            )

    try:
        await mailer.send_signup_code(code, body.email)
    except Exception as error:
        # The row survives a failed send, holding its cooldown. Saying so plainly beats a
        # code screen waiting on mail that was never accepted.
        logger.error("signup code send failed: %s", error)
        raise APIError(502, "Could not send the code. Try again in a moment.") from error

    logger.info("signup code sent")
    return CodeSentResponse(
        expiresIn=config.signup_code_ttl, resendIn=config.signup_code_resend_cooldown
    )


@router.post(
    "/v1/auth/signup/verify", response_model=SessionResponse, response_model_exclude_none=True
)
async def verify_signup_code(request: Request) -> SessionResponse:
    """Step two: check the code, and only now create the account.

    The function answers with an outcome rather than raising, because a raise would roll
    back the attempt counter it had just incremented — the cap would read as enforced while
    a script guessed six digits at its leisure. Every failure answers with the same words,
    so the response cannot be used to learn whether an address has a sign-up in flight.
    """
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    body = await _decode(request, VerifyCodeRequest)

    with _translating(logger):
        async with store.without_tenant() as connection:
            row = await connection.fetchrow(
                """
                SELECT outcome, user_id, email, display_name, timezone
                FROM public.auth_verify_signup_code($1, $2)
                """,
                body.email,
                body.code,
            )
    outcome, user = _outcome_of(row)

    if outcome != "created" or user is None:
        raise APIError(401, _code_failure(outcome))
    return await _issue_session(request, user, body.deviceId)


def _code_failure(outcome: str) -> str:
    """A sentence for each way a code can fail.

    Expiry and a spent attempt budget are told apart from a wrong code on purpose: all three
    end the attempt, but only one is worth retyping, and a person who cannot tell them apart
    retypes the same dead code until they give up. None of them reveals whether the address
    had a request in flight.
    """
    match outcome:
        case "code-expired":
            return "That code has expired. Ask for a new one."
        case "too-many-attempts":
            return "Too many wrong codes. Ask for a new one."
        case "email-taken":
            return "That address already has an account. Sign in instead."
        case _:
            return "That code is not right."


@router.post("/v1/auth/password", response_model=SessionResponse, response_model_exclude_none=True)
async def sign_in_with_password(request: Request) -> SessionResponse:
    limiter: RateLimiter = request.app.state.limiter
    logger: logging.Logger = request.app.state.logger
    body = await _decode(request, PasswordRequest)

    # Per address as well as per caller. The middleware bounds what one source can spend;
    # this bounds what any number of sources can spend on one account, which is the shape a
    # real credential-stuffing run takes. Tighter than the per-caller limit, because nobody
    # mistypes their own password ten times a minute.
    address_key = f"pw:{body.email.lower()}"
    retry_after = limiter.seconds_until_allowed(address_key, limit=10, window=300.0)
    if retry_after is not None:
        logger.warning("password attempts throttled for one address")
        raise APIError(
            429,
            f"Too many attempts for that account. Try again in {retry_after} seconds.",
            {"Retry-After": str(retry_after)},
        )

    try:
        user = await _user_returned_by(
            request,
            """
            SELECT id, email, display_name, timezone
            FROM public.auth_sign_in_with_password($1, $2)
            """,
            body.email,
            body.password,
        )
        return await _issue_session(request, user, body.deviceId)
    except Exception:
        # Only failures count against the account. Signing in correctly on several devices
        # is not an attack, and metering it would lock out the person who did nothing wrong.
        limiter.record(address_key, window=300.0)
        raise


@router.post("/v1/auth/set-password")
async def set_password(request: Request) -> dict[str, bool]:
    """Add or change a password on an account the caller is already signed into.

    This is the safe route into password sign-in for someone who started with Google: the
    access token has already established who they are, so nothing further needs proving. It
    is also why sign-up may refuse a known address outright rather than inventing an
    email-verification flow.

    It also ends every *other* session. That is the reason most people change a password —
    they believe somebody else is in the account — and a new password that leaves the
    intruder's ninety-day refresh chain running answers the wrong half of the problem. The
    device doing the changing keeps its session; signing it out too would only teach people
    that changing a password is a nuisance.
    """
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    tokens: TokenService = request.app.state.tokens

    user_id, session_id = await _authenticated(request)
    body = await _decode(request, SetPasswordRequest)

    with _translating(logger):
        async with store.without_tenant() as connection:
            await connection.execute(
                "SELECT public.auth_set_password($1, $2)", user_id, body.password
            )
            # Same transaction as the password itself: a change that took effect while the
            # old sessions survived is the state this route exists to prevent, and two
            # statements outside one would allow it on a fault.
            rows = await connection.fetch(
                "SELECT public.auth_revoke_other_sessions($1, $2)", user_id, session_id
            )
    ended = [row[0] for row in rows if row[0] is not None]

    # The database revocation cannot reach an access token already in somebody's hands.
    for session in ended:
        tokens.revoke(session)
    if ended:
        logger.info(
            "password changed; other sessions ended user=%s sessions=%d", user_id, len(ended)
        )
    return {"ok": True}


@router.post("/v1/auth/signout")
async def sign_out(request: Request) -> dict[str, bool]:
    """End this session, on the server as well as on the device.

    Idempotent, and deliberately so: a client that cannot reach this route clears its own
    tokens anyway and may well call it again on the next launch. Revoking an already-revoked
    chain updates nothing.
    """
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    tokens: TokenService = request.app.state.tokens

    user_id, session_id = await _authenticated(request)
    with _translating(logger):
        async with store.without_tenant() as connection:
            await connection.execute("SELECT public.auth_revoke_session($1)", session_id)
    tokens.revoke(session_id)
    logger.info("session ended user=%s", user_id)
    return {"ok": True}


@router.post("/v1/auth/refresh", response_model=SessionResponse, response_model_exclude_none=True)
async def refresh(request: Request) -> SessionResponse:
    """Trade a refresh token for a new pair, rotating it.

    The rotation function returns an outcome instead of raising, because raising would roll
    back the revocation it had just performed — a replay would be reported while the stolen
    token quietly stayed alive. Every failure answers 401 with the same words, so a caller
    cannot learn from the response whether a token ever existed.
    """
    config: Config = request.app.state.config
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    tokens: TokenService = request.app.state.tokens

    body = await _decode(request, RefreshRequest)
    old_hash = RefreshToken.digest(body.refreshToken)
    new_token = RefreshToken.generate()
    new_hash = RefreshToken.digest(new_token)
    expiry = _now_ms() + int(config.refresh_token_ttl * 1000)

    with _translating(logger):
        async with store.without_tenant() as connection:
            row = await connection.fetchrow(
                """
                SELECT outcome, user_id, email, display_name, timezone
                FROM public.auth_rotate_refresh_token($1, $2, $3)
                """,
                old_hash,
                new_hash,
                expiry,
            )
    outcome, user = _outcome_of(row)

    if outcome != "rotated" or user is None:
        if outcome == "replayed":
            # The chain is revoked in the database by now. The access tokens on it are the
            # half that revocation could never reach, and this is the case where that
            # matters most: a replay means somebody has a copy.
            try:
                tokens.revoke(await _session_of(request, old_hash))
            except Exception:  # noqa: BLE001 — nothing here is worth failing the 401 over
                logger.warning("could not revoke the replayed session in memory")
            logger.warning("refresh token replayed; session revoked")
        raise APIError(401, "That session has ended. Sign in again.")

    # The rotated token stays on the same chain, so the access token must carry the same
    # session id or the two would describe different sessions.
    session_id = await _session_of(request, new_hash)
    access = await tokens.issue_access_token(UUID(user.id), session_id)
    return SessionResponse(
        accessToken=access,
        refreshToken=new_token,
        expiresIn=int(config.access_token_ttl),
        user=user,
    )


# -------------------------------------------------------------------- Shared


async def _decode[T: BaseModel](request: Request, model: type[T]) -> T:
    """The body, or a 400.

    FastAPI's own answer to a body it cannot validate is a 422 wrapped in `detail`, and both
    halves of that are off-contract — which is why routes here take the raw request and
    parse it themselves.
    """
    try:
        return model.model_validate(await request.json())
    except ValueError as error:  # both json.JSONDecodeError and pydantic's ValidationError
        raise APIError(400, "That request body could not be read.") from error


async def _authenticated(request: Request) -> tuple[UUID, UUID]:
    """The user and session behind a bearer token, or a 401.

    One copy, because two routes need it and a second hand-rolled header parse is how one of
    them ends up checking something the other does not.
    """
    tokens: TokenService = request.app.state.tokens
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        try:
            claims = await tokens.verify_access_token(header.removeprefix("Bearer "))
            return UUID(claims.sub), UUID(claims.sid)
        except TokenError, ValueError:
            pass
    raise APIError(401, "A bearer token is required.")


async def _issue_session(
    request: Request, user: UserDTO, device_id: UUID | None
) -> SessionResponse:
    config: Config = request.app.state.config
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    tokens: TokenService = request.app.state.tokens

    session_id = uuid4()
    refresh_token = RefreshToken.generate()
    expiry = _now_ms() + int(config.refresh_token_ttl * 1000)

    with _translating(logger):
        async with store.without_tenant() as connection:
            await connection.execute(
                """
                SELECT public.auth_issue_refresh_token($1, $2, $3, $4, $5)
                """,
                UUID(user.id),
                session_id,
                RefreshToken.digest(refresh_token),
                device_id,
                expiry,
            )

    access = await tokens.issue_access_token(UUID(user.id), session_id)
    logger.info("session issued user=%s", user.id)
    return SessionResponse(
        accessToken=access,
        refreshToken=refresh_token,
        expiresIn=int(config.access_token_ttl),
        user=user,
    )


async def _session_of(request: Request, token_hash: bytes) -> UUID:
    """The chain a stored refresh token belongs to."""
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    with _translating(logger):
        async with store.without_tenant() as connection:
            session_id = await connection.fetchval(
                "SELECT public.auth_session_for_token($1)", token_hash
            )
    if session_id is None:
        raise APIError(500, "The session could not be renewed.")
    return session_id


async def _user_returned_by(request: Request, query: str, *arguments: object) -> UserDTO:
    """Run a function that returns one user row, translating its refusals."""
    logger: logging.Logger = request.app.state.logger
    store: Store = request.app.state.store
    with _translating(logger):
        async with store.without_tenant() as connection:
            row = await connection.fetchrow(query, *arguments)
    if row is None or row["id"] is None:
        raise APIError(401, "Those details were not accepted.")
    return _user(row["id"], row["email"], row["display_name"], row["timezone"])


def _outcome_of(row: asyncpg.Record | None) -> tuple[str, UserDTO | None]:
    """The (outcome, user) pair the verify and rotate functions both answer with.

    A row whose user columns are null is a refusal carrying its reason, not a user.
    """
    if row is None:
        return ("unknown", None)
    if row["user_id"] is None or row["email"] is None or row["timezone"] is None:
        return (row["outcome"], None)
    return (
        row["outcome"],
        _user(row["user_id"], row["email"], row["display_name"], row["timezone"]),
    )


def _user(user_id: UUID, email: str, display_name: str | None, timezone: str) -> UserDTO:
    # Lowercase on the wire. Uppercase is for the inside of a token, where Swift's
    # UUID.uuidString set the shape and both implementations have to agree.
    return UserDTO(
        id=str(user_id).lower(), email=email, displayName=display_name, timezone=timezone
    )


def _now_ms() -> int:
    return int(time.time() * 1000)


#: Every sentinel a SECURITY DEFINER function raises, and the answer it earns.
#:
#: Wrong password and unknown address both become the same sentence on purpose:
#: distinguishing them would let anyone test which addresses are registered.
_REFUSALS: dict[str, tuple[int, str]] = {
    "email-taken": (
        409,
        (
            "That email already has an account. Sign in instead — "
            "if you created it with Google, use Continue with Google."
        ),
    ),
    "weak-password": (400, "Passwords must be 8 to 72 characters."),
    # Not a failure from where the person is standing: a code is already in their inbox and
    # still good. Answering 429 rather than 500 is what lets the client take them to the
    # code screen instead of a dead end.
    "resend-too-soon": (429, "A code was already sent to that address. Check your email."),
    # The address Google now reports already belongs to a different account here. The
    # sign-in itself was fine, so this says which of the two facts is in the way rather than
    # reporting a failure at Google.
    "email-collision": (
        409,
        (
            "That Google address already belongs to another Deylee account. "
            "Sign in to that one, or change the address on one of them."
        ),
    ),
    "unverified-email": (401, "Google has not verified that address."),
    "invalid-credentials": (401, "That email and password do not match."),
    "no-such-user": (401, "That account no longer exists."),
}


@contextmanager
def _translating(logger: logging.Logger) -> Iterator[None]:
    """Turn a database refusal into something a person can act on.

    An APIError passes through untouched: re-mapping a deliberate 401 or 409 would replace a
    considered answer with whatever the last exception happened to look like.
    """
    try:
        yield
    except APIError:
        raise
    except Exception as error:
        raise _mapped(error, logger) from error


def _mapped(error: Exception, logger: logging.Logger) -> APIError:
    # 503 rather than 500, because this one is worth retrying and the other is not. The
    # distinction is the whole reason the deadline exists: without it the request would
    # still be waiting, and a client cannot retry something that has not finished failing.
    if isinstance(error, StoreTimedOut):
        return APIError(503, UNAVAILABLE_MESSAGE)
    if isinstance(error, asyncpg.PostgresError):
        refusal = _REFUSALS.get(error.message or str(error))
        if refusal is not None:
            return APIError(*refusal)
    return _unexplained(error, logger)


def _unexplained(error: Exception, logger: logging.Logger) -> APIError:
    """The generic 500 — but never a silent one.

    Returning the same opaque sentence is right: a database's own wording leaks schema and
    is no use to the person reading it. Saying nothing *server-side* is not. A deliberate
    401 or 409 is an answer rather than a fault and is logged nowhere, but the moment a
    database error is converted into one here it stops being visible anywhere, and the only
    evidence left is a client reporting a blank failure.

    That has hidden three separate faults already: a refusal whose sentinel was never added
    to the table above, an argument bound as the wrong integer width so no function overload
    matched, and the collision the table was last extended for. All three looked identical
    from outside and left nothing behind.
    """
    if isinstance(error, asyncpg.PostgresError):
        logger.error(
            "unmapped database error sqlstate=%s message=%s",
            error.sqlstate or "none",
            # The message is the sentinel that was never added to the table, on the day it
            # turns out one is missing.
            error.message or "none",
        )
    else:
        logger.error("unmapped error: %r", error)
    return APIError(500, "The request could not be completed.")

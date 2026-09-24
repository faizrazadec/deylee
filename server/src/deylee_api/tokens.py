"""Verifies Google's ID tokens and mints this API's own.

Two different algorithms are in play and conflating them is a real bug, not a
technicality. Google signs ID tokens with RS256 against rotating RSA keys it publishes.
This API signs its own access tokens with ES256 against a P-256 key it holds. A verifier
written for one silently rejects the other, so the two live in separate methods with
separate keys.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from uuid import UUID

import httpx
import jwt
from cryptography.hazmat.primitives.serialization import load_pem_private_key

from deylee_api.config import Config

#: Floor between refetches of Google's key set.
#:
#: An unknown `kid` triggers a refresh, and an unknown `kid` is something an attacker can
#: produce at will by signing garbage. Without a floor, that is a free amplified request
#: to Google on every forged token.
MINIMUM_REFRESH_INTERVAL = 300.0


class TokenError(Exception):
    """A refusal with a sentence a client can be shown. `str(error)` is that sentence."""

    @classmethod
    def audience_rejected(cls) -> TokenError:
        return cls("The token was issued for a different application.")

    @classmethod
    def issuer_rejected(cls, got: str) -> TokenError:
        return cls(f"The token was issued by {got}, which is not Google.")

    @classmethod
    def email_unverified(cls) -> TokenError:
        return cls("Google has not verified that email address.")

    @classmethod
    def hosted_domain_rejected(cls, got: str | None) -> TokenError:
        return cls(
            f"Sign-in is restricted to one Workspace domain; this account is in {got or 'none'}."
        )

    @classmethod
    def jwks_unavailable(cls) -> TokenError:
        return cls("Google's signing keys could not be fetched.")

    @classmethod
    def nonce_mismatch(cls) -> TokenError:
        return cls("That token was not issued for this sign-in.")

    @classmethod
    def invalid(cls, why: str) -> TokenError:
        return cls(f"The token is not valid: {why}")


@dataclass(frozen=True, slots=True)
class GoogleClaims:
    """The subset of Google's ID token claims that matter here."""

    iss: str
    sub: str
    aud: tuple[str, ...]
    exp: int
    email: str | None
    email_verified: bool | None
    name: str | None
    #: Present only for Google Workspace accounts. A personal gmail.com account has none,
    #: which is why a hosted-domain check must treat None as "no domain" rather than as a
    #: value to compare.
    hd: str | None
    #: Echoed back from the authorization request. Absent on a token minted for a request
    #: that never sent one — which, now that the client always does, means the token was
    #: not minted for this sign-in.
    nonce: str | None


@dataclass(frozen=True, slots=True)
class SessionClaims:
    """The access token this API issues and verifies."""

    sub: str
    iss: str
    exp: int
    iat: int
    #: The refresh chain this access token belongs to. Carried so a revoked chain can be
    #: recognised without a database round trip on every request.
    sid: str


async def _get(url: str) -> bytes:
    async with httpx.AsyncClient() as client:
        response = await client.get(url)
        response.raise_for_status()
        return response.content


class TokenService:
    def __init__(
        self, config: Config, fetch: Callable[[str], Awaitable[bytes]] | None = None
    ) -> None:
        self._config = config
        # Injectable so tests supply a key set without touching the network.
        self._fetch = fetch or _get
        self._private_key = load_pem_private_key(
            config.session_private_key_pem.encode(), password=None
        )
        self._public_key = self._private_key.public_key()

        self._google_keys: jwt.PyJWKSet | None = None
        self._google_keys_loaded_at: float | None = None
        # The cached key set is mutable shared state: several requests can discover the
        # same unknown key id at once, and without this they would each refetch. (The
        # Swift version was an actor for exactly this.)
        self._refresh_lock = asyncio.Lock()

        # Session ids whose access tokens have stopped counting, each with the moment it
        # stops mattering.
        #
        # Revoking a session revokes its refresh chain, and until this existed that was
        # the whole of it: the access token already in the thief's hands stayed valid for
        # the rest of its hour, so signing out did nothing a stolen session could feel.
        # An entry only has to outlive the longest-lived token carrying that id, which is
        # one access-token lifetime from the moment of revocation.
        #
        # ponytail: one process's memory. A second replica keeps its own set and would
        # honour a token this one refuses; the upgrade is a shared cache, or reading
        # `refresh_tokens.revoked_at` per request if the round trip is ever affordable.
        self._revoked_sessions: dict[str, float] = {}

    # ------------------------------------------------------------------ Google

    async def verify_google_id_token(self, token: str, nonce: str) -> GoogleClaims:
        """Verify a Google ID token and return its claims, or explain the refusal.

        `nonce` is the value the client put in its authorization request; the token must
        echo it. Without this check, an ID token obtained anywhere else for the same
        `aud` is indistinguishable from one minted for this sign-in. Not optional,
        deliberately: a nonce the caller may leave out is one an attacker leaves out —
        the body is theirs to write — and the check would then protect only the clients
        that were never the threat.

        Every claim check lives in this one function. A token verified in one place while
        one of its checks is forgotten in another is the failure a single call site
        prevents.
        """
        await self._ensure_google_keys()

        try:
            payload = self._decode_google(token)
        except jwt.PyJWTError as error:
            # Most likely a key rotation: Google published a new one after our last
            # fetch. Refresh once and retry before calling the token invalid.
            if not await self._refresh_google_keys_if_allowed():
                raise TokenError.invalid(str(error)) from error
            try:
                payload = self._decode_google(token)
            except jwt.PyJWTError as retried:
                # Swift let this second failure escape as a raw JWT error, which the auth
                # route turned into a 500. A signature that does not check out is a
                # refusal, not a fault.
                raise TokenError.invalid(str(retried)) from retried

        issuer = str(payload["iss"])
        if issuer not in self._config.google_issuers:
            raise TokenError.issuer_rejected(issuer)

        # `aud` identifies which of our OAuth clients the token was minted for. A token
        # for someone else's Google project is a perfectly valid Google token and must
        # still be refused, which is why this is an explicit set.
        raw_audience = payload["aud"]
        audience = tuple(raw_audience) if isinstance(raw_audience, list) else (str(raw_audience),)
        if not any(entry in self._config.google_audiences for entry in audience):
            raise TokenError.audience_rejected()

        # An unverified address must not identify anybody: on some providers it can be
        # claimed without ever proving control of the mailbox.
        email_verified = payload.get("email_verified")
        if email_verified is not True:
            raise TokenError.email_unverified()

        if payload.get("nonce") != nonce:
            raise TokenError.nonce_mismatch()

        hosted_domain = payload.get("hd")
        required_domain = self._config.google_allowed_hosted_domain
        if required_domain is not None and hosted_domain != required_domain:
            raise TokenError.hosted_domain_rejected(hosted_domain)

        return GoogleClaims(
            iss=issuer,
            sub=str(payload["sub"]),
            aud=audience,
            exp=int(payload["exp"]),
            email=payload.get("email"),
            email_verified=email_verified,
            name=payload.get("name"),
            hd=hosted_domain,
            nonce=payload.get("nonce"),
        )

    def _decode_google(self, token: str) -> dict[str, Any]:
        """Signature and expiry only.

        Audience and issuer are deliberately left to the caller — PyJWT skips either
        check silently when the corresponding argument is absent, and a check that can be
        skipped by omission is one that will be.
        """
        kid = jwt.get_unverified_header(token).get("kid")
        published = self._google_keys.keys if self._google_keys else []
        key = next((candidate for candidate in published if candidate.key_id == kid), None)
        if key is None:
            raise jwt.InvalidKeyError(f"Google publishes no signing key with id {kid!r}")
        return jwt.decode(
            token,
            key.key,
            algorithms=["RS256"],
            options={
                "verify_aud": False,
                "verify_iss": False,
                "require": ["iss", "sub", "aud", "exp"],
            },
        )

    async def _ensure_google_keys(self) -> None:
        if self._google_keys_loaded_at is not None:
            return
        async with self._refresh_lock:
            if self._google_keys_loaded_at is not None:
                return  # another request loaded them while we waited
            if not await self._load_google_keys():
                raise TokenError.jwks_unavailable()

    async def _refresh_google_keys_if_allowed(self) -> bool:
        async with self._refresh_lock:
            loaded = self._google_keys_loaded_at
            if loaded is not None and time.monotonic() - loaded < MINIMUM_REFRESH_INTERVAL:
                return False
            return await self._load_google_keys()

    async def _load_google_keys(self) -> bool:
        """True when a key set was fetched and parsed. Any failure is just a False: the
        caller either retries later or refuses the token, and neither wants an exception
        from Google's availability."""
        try:
            body = await self._fetch(self._config.google_jwks_url)
            self._google_keys = jwt.PyJWKSet.from_dict(json.loads(body))
        except Exception:  # noqa: BLE001 — Google being down must not become a 500
            return False
        # Monotonic, so a clock correction cannot hand out a free refetch window.
        self._google_keys_loaded_at = time.monotonic()
        return True

    # ------------------------------------------------------------ Our sessions

    async def issue_access_token(
        self, user_id: UUID, session_id: UUID, now: datetime | None = None
    ) -> str:
        moment = int((now or datetime.now(UTC)).timestamp())
        return jwt.encode(
            {
                # Uppercase, because Swift wrote these with UUID.uuidString and tokens
                # issued by either implementation have to verify against the other.
                "sub": str(user_id).upper(),
                "iss": self._config.session_issuer,
                "exp": moment + int(self._config.access_token_ttl),
                "iat": moment,
                "sid": str(session_id).upper(),
            },
            self._private_key,
            algorithm="ES256",
        )

    def revoke(self, session_id: UUID, now: datetime | None = None) -> None:
        """Stop honouring access tokens on this session.

        Called beside every database revocation rather than instead of it. The database is
        what makes a revocation survive a restart; this is what makes it take effect
        before the hour is out.
        """
        moment = (now or datetime.now(UTC)).timestamp()
        self._revoked_sessions[str(session_id).upper()] = moment + self._config.access_token_ttl
        # Swept here because this is the only thing that makes the map grow, and it is
        # rare — a sign-out, a password change, a replayed token.
        self._revoked_sessions = {
            session: until for session, until in self._revoked_sessions.items() if until > moment
        }

    async def verify_access_token(self, token: str, now: datetime | None = None) -> SessionClaims:
        try:
            payload = jwt.decode(
                token,
                self._public_key,
                algorithms=["ES256"],
                options={
                    "verify_aud": False,
                    # Expiry is the control; `iat` decides nothing here. PyJWT refuses a
                    # token whose `iat` is ahead of the verifier's clock, which JWTKit
                    # never did — it checked `exp` alone. Left on, two replicas a second
                    # apart would refuse each other's freshly minted tokens and sign
                    # people out over clock skew, a failure the Swift server never had.
                    "verify_iat": False,
                    "require": ["sub", "iss", "exp", "iat", "sid"],
                },
            )
        except jwt.PyJWTError as error:
            # Wrapped rather than propagated: the routes answer a TokenError with a 401,
            # and an expired signature is exactly that answer, not a server fault.
            raise TokenError.invalid(str(error)) from error

        issuer = str(payload["iss"])
        if issuer != self._config.session_issuer:
            raise TokenError.issuer_rejected(issuer)

        # Checked here rather than in the routes: three of them verify a token, and a
        # guard added to two of the three is a revocation that works everywhere except
        # the one place somebody forgot.
        moment = (now or datetime.now(UTC)).timestamp()
        until = self._revoked_sessions.get(str(payload["sid"]).upper())
        if until is not None and until > moment:
            raise TokenError.invalid("that session has been signed out")

        return SessionClaims(
            sub=str(payload["sub"]),
            iss=issuer,
            exp=int(payload["exp"]),
            iat=int(payload["iat"]),
            sid=str(payload["sid"]),
        )


class RefreshToken:
    """A refresh token: high-entropy, opaque, and stored only as a digest.

    Opaque rather than a JWT on purpose. A JWT is self-describing and valid until it
    expires, which is the opposite of what a refresh token needs — the whole point is that
    presenting one can be refused because of state on the server.
    """

    @staticmethod
    def generate() -> str:
        """256 bits from the system CSPRNG, standard base64 with padding — the encoding
        Swift's `Data.base64EncodedString()` produced, so tokens already in the wild are
        still the same string."""
        return base64.b64encode(secrets.token_bytes(32)).decode()

    @staticmethod
    def digest(token: str) -> bytes:
        """SHA-256, matching the `octet_length(token_hash) = 32` constraint on the table.
        Only this ever reaches the database."""
        return hashlib.sha256(token.encode()).digest()

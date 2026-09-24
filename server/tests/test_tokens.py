"""Two different algorithms are in play and conflating them is a real bug: Google signs
ID tokens with RS256 against rotating RSA keys it publishes, and this API signs its own
access tokens with ES256 against a P-256 key it holds. Both halves are pinned here.

Revoking a session has to stop its access tokens, not only its refresh chain. The gap
that pinned closed: `sid` was minted into every access token and read by nothing, so
`auth_revoke_session` ended the ninety-day chain while the token already in someone's
hands went on being honoured for the rest of its hour.

No database anywhere in this file. The revocation check lives in `TokenService` —
deliberately, because three routes verify a token and a guard added to two of them is a
revocation with a hole in it — and `TokenService` never opens a connection.

The Google half had no unit test at all in Swift; it was only ever exercised against the
real endpoint. Here a fake JWKS serves an RSA key through the injectable `fetch`, so every
refusal is a test rather than a hope.
"""

import json
import time
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import jwt
import pytest
from conftest import TEST_PRIVATE_KEY_PEM, load_env, valid_env
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from jwt.algorithms import RSAAlgorithm

from deylee_api.tokens import MINIMUM_REFRESH_INTERVAL, TokenError, TokenService

AUDIENCE = "111-ios.apps.googleusercontent.com"
NONCE = "the-nonce-this-sign-in-sent"

# Generated once: a 2048-bit key costs about a tenth of a second, and every test in the
# file wants the same pair anyway.
GOOGLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
IMPOSTOR_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def service(**overrides: str) -> TokenService:
    return TokenService(load_env(valid_env(**overrides)))


class FakeGoogle:
    """Google's JWKS endpoint, minus Google.

    Serves one RSA public key through the `fetch` the service takes, counts how often it
    is asked, and signs ID tokens with the matching private half.
    """

    kid = "test-signing-key"

    def __init__(self) -> None:
        self.fetches = 0

    async def fetch(self, url: str) -> bytes:
        self.fetches += 1
        jwk = json.loads(RSAAlgorithm.to_jwk(GOOGLE_KEY.public_key()))
        return json.dumps(
            {"keys": [jwk | {"kid": self.kid, "alg": "RS256", "use": "sig"}]}
        ).encode()

    def id_token(self, *, key: rsa.RSAPrivateKey | None = None, kid: str | None = None, **claims):
        """A well-formed Google ID token. A claim passed as None is dropped rather than
        emitted null, which is how a test says "Google left this out"."""
        now = int(time.time())
        payload = {
            "iss": "https://accounts.google.com",
            "sub": "104729000000000000001",
            "aud": AUDIENCE,
            "exp": now + 600,
            "iat": now,
            "email": "person@example.test",
            "email_verified": True,
            "name": "A Person",
            "nonce": NONCE,
        } | claims
        return jwt.encode(
            {name: value for name, value in payload.items() if value is not None},
            key or GOOGLE_KEY,
            algorithm="RS256",
            headers={"kid": kid or self.kid},
        )


@pytest.fixture
def google() -> FakeGoogle:
    return FakeGoogle()


def with_google(google: FakeGoogle, **overrides: str) -> TokenService:
    return TokenService(load_env(valid_env(**overrides)), fetch=google.fetch)


# ------------------------------------------------------------- our own sessions


async def test_issues_an_access_token_that_it_can_verify():
    tokens = service()
    user, session = uuid4(), uuid4()

    claims = await tokens.verify_access_token(await tokens.issue_access_token(user, session))

    assert claims.sub == str(user).upper()
    assert claims.sid == str(session).upper()
    assert claims.iss == "https://api.deylee.app"


async def test_refuses_an_expired_access_token():
    """An expired token must be refused by the same call that accepts a live one — the
    check belongs in verification, not at the call sites."""
    tokens = service(ACCESS_TOKEN_TTL_SECONDS="60")
    stale = await tokens.issue_access_token(
        uuid4(), uuid4(), now=datetime.now(UTC) - timedelta(hours=1)
    )
    with pytest.raises(TokenError):
        await tokens.verify_access_token(stale)


async def test_refuses_a_token_from_another_issuer():
    """A token signed by a different deployment must not be honoured here."""
    theirs = service(SESSION_JWT_ISSUER="https://api.someone-else.example")
    ours = service()
    foreign = await theirs.issue_access_token(uuid4(), uuid4())

    with pytest.raises(TokenError, match="which is not Google"):
        await ours.verify_access_token(foreign)


async def test_a_revoked_sessions_access_token_stops_verifying():
    tokens = service()
    user, session = uuid4(), uuid4()
    access = await tokens.issue_access_token(user, session)

    before = await tokens.verify_access_token(access)
    assert before.sub == str(user).upper()

    tokens.revoke(session)

    with pytest.raises(TokenError, match="signed out"):
        await tokens.verify_access_token(access)


async def test_revoking_one_session_leaves_the_others_alone():
    tokens = service()
    kept = uuid4()
    kept_token = await tokens.issue_access_token(uuid4(), kept)

    # The password-change case: every session but this one ends.
    tokens.revoke(uuid4())
    tokens.revoke(uuid4())

    claims = await tokens.verify_access_token(kept_token)
    assert claims.sid == str(kept).upper(), "the caller's own session was signed out"


async def test_a_revocation_stops_being_remembered_once_its_tokens_have_expired():
    """An entry is only needed for as long as a token carrying that id could still be
    inside its expiry. Holding them forever would be a slow leak on a process meant to run
    for months."""
    tokens = service(ACCESS_TOKEN_TTL_SECONDS="60")
    session = uuid4()
    access = await tokens.issue_access_token(uuid4(), session)

    revoked_at = datetime.now(UTC)
    tokens.revoke(session, now=revoked_at)

    # Still refused inside the window, on the token's own merits *and* the entry.
    with pytest.raises(TokenError):
        await tokens.verify_access_token(access, now=revoked_at + timedelta(seconds=30))

    # Past it the entry is gone, and the only thing still refusing a token with this sid
    # is its own expiry — which is the point: the map does not grow without bound.
    later = revoked_at + timedelta(hours=1)
    fresh = await tokens.issue_access_token(uuid4(), session, now=later)
    assert (await tokens.verify_access_token(fresh, now=later)).sid == str(session).upper()


# --------------------------------------------------------- Swift compatibility


async def test_a_token_minted_by_the_swift_build_still_verifies():
    """Swift wrote UUIDs into `sub` and `sid` with UUID.uuidString, which is uppercase.
    A rolling deploy runs both implementations at once, so a token from either has to
    verify in the other — same key, same claims, same case."""
    config = load_env(valid_env())
    tokens = TokenService(config)
    user, session = uuid4(), uuid4()
    now = int(time.time())

    swift_token = jwt.encode(
        {
            "sub": str(user).upper(),
            "iss": config.session_issuer,
            "exp": now + 3600,
            "iat": now,
            "sid": str(session).upper(),
        },
        load_pem_private_key(TEST_PRIVATE_KEY_PEM.encode(), password=None),
        algorithm="ES256",
    )

    claims = await tokens.verify_access_token(swift_token)
    assert claims.sub == str(user).upper()
    assert claims.sid == str(session).upper()


async def test_the_tokens_we_mint_carry_uppercase_uuids_and_nothing_extra():
    """The other direction: a Swift build verifying one of ours. It decodes `sub` and
    `sid` with UUID(uuidString:), and an unexpected claim is a decode failure there."""
    tokens = service()
    user, session = uuid4(), uuid4()

    payload = jwt.decode(
        await tokens.issue_access_token(user, session), options={"verify_signature": False}
    )

    assert set(payload) == {"sub", "iss", "exp", "iat", "sid"}
    assert payload["sub"] == str(user).upper()
    assert payload["sid"] == str(session).upper()


async def test_revocation_matches_a_session_id_whatever_its_case():
    """Parsing stays case-insensitive even though minting does not: a token written by
    some other client with a lowercase `sid` must still be caught by a revocation."""
    config = load_env(valid_env())
    tokens = TokenService(config)
    session = UUID("11111111-2222-3333-4444-555555555555")
    now = int(time.time())

    lowercase = jwt.encode(
        {
            "sub": str(uuid4()).lower(),
            "iss": config.session_issuer,
            "exp": now + 3600,
            "iat": now,
            "sid": str(session).lower(),
        },
        load_pem_private_key(TEST_PRIVATE_KEY_PEM.encode(), password=None),
        algorithm="ES256",
    )

    tokens.revoke(session)
    with pytest.raises(TokenError, match="signed out"):
        await tokens.verify_access_token(lowercase)


# ------------------------------------------------------------ Google ID tokens


async def test_accepts_a_well_formed_google_id_token(google):
    tokens = with_google(google)
    claims = await tokens.verify_google_id_token(google.id_token(), NONCE)

    assert claims.sub == "104729000000000000001"
    assert claims.email == "person@example.test"
    assert claims.email_verified is True
    assert claims.aud == (AUDIENCE,)


async def test_refuses_a_token_minted_for_another_application(google):
    """A token for someone else's Google project is a perfectly valid Google token, and
    must still be refused."""
    tokens = with_google(google)
    with pytest.raises(TokenError, match="issued for a different application"):
        await tokens.verify_google_id_token(google.id_token(aud="999-someone-else"), NONCE)


async def test_refuses_a_google_token_from_another_issuer(google):
    tokens = with_google(google)
    with pytest.raises(TokenError, match="which is not Google"):
        await tokens.verify_google_id_token(
            google.id_token(iss="https://accounts.evil.example"), NONCE
        )


@pytest.mark.parametrize("verified", [False, None], ids=["false", "absent"])
async def test_refuses_an_unverified_email(google, verified):
    """An unverified address must not identify anybody: on some providers it can be
    claimed without ever proving control of the mailbox."""
    tokens = with_google(google)
    with pytest.raises(TokenError, match="has not verified"):
        await tokens.verify_google_id_token(google.id_token(email_verified=verified), NONCE)


@pytest.mark.parametrize("minted_with", ["some-other-sign-in", None], ids=["mismatch", "absent"])
async def test_refuses_a_token_whose_nonce_is_not_the_one_this_sign_in_sent(google, minted_with):
    """The nonce ARGUMENT is what is compared, not merely the claim's presence. Without
    that, an ID token obtained anywhere else for the same `aud` is indistinguishable from
    one minted for this sign-in."""
    tokens = with_google(google)
    with pytest.raises(TokenError, match="not issued for this sign-in"):
        await tokens.verify_google_id_token(google.id_token(nonce=minted_with), NONCE)


async def test_refuses_an_account_outside_the_allowed_workspace_domain(google):
    tokens = with_google(google, GOOGLE_ALLOWED_HD="snapdev.ai")
    with pytest.raises(TokenError, match="restricted to one Workspace domain"):
        await tokens.verify_google_id_token(google.id_token(hd="somewhere-else.example"), NONCE)

    accepted = await tokens.verify_google_id_token(google.id_token(hd="snapdev.ai"), NONCE)
    assert accepted.hd == "snapdev.ai"


async def test_accepts_a_personal_account_when_no_domain_is_required(google):
    """A personal gmail.com account carries no `hd` at all, so the check has to treat its
    absence as "no domain" rather than as a value to compare."""
    tokens = with_google(google)
    claims = await tokens.verify_google_id_token(google.id_token(), NONCE)
    assert claims.hd is None


async def test_refuses_an_expired_google_token(google):
    tokens = with_google(google)
    expired = google.id_token(exp=int(time.time()) - 60)
    with pytest.raises(TokenError, match="not valid"):
        await tokens.verify_google_id_token(expired, NONCE)


async def test_refuses_a_token_signed_by_a_different_key(google):
    """Same `kid`, different key: the forgery that a verifier trusting the header alone
    would let through."""
    tokens = with_google(google)
    forged = google.id_token(key=IMPOSTOR_KEY)
    with pytest.raises(TokenError, match="not valid"):
        await tokens.verify_google_id_token(forged, NONCE)


async def test_an_unknown_key_id_does_not_buy_a_refetch_of_googles_key_set(google):
    """An unknown `kid` triggers a refresh, and an unknown `kid` is something an attacker
    mints at will. Without the floor, each forgery is a free amplified request to Google.
    """
    tokens = with_google(google)

    for attempt in range(20):
        with pytest.raises(TokenError):
            await tokens.verify_google_id_token(google.id_token(kid=f"forged-{attempt}"), NONCE)

    assert MINIMUM_REFRESH_INTERVAL == 300.0
    assert google.fetches == 1, "the key set was refetched inside the refresh floor"

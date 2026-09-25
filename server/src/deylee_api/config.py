"""Everything the API needs from its environment, read once at boot.

Read once and passed around rather than looked up at each use, so a missing variable
stops the process on the first line of `main` instead of failing the first request
that happens to need it — quite possibly in production, hours later, on a code path
nobody exercised.
"""

import base64
import binascii
import os
from collections.abc import Callable
from dataclasses import dataclass
from urllib.parse import urlsplit

Lookup = Callable[[str], str | None]


@dataclass(frozen=True, slots=True)
class Config:
    google_audiences: frozenset[str]
    """Google OAuth client ids we will accept an ID token from.

    Google stamps a different `aud` on each platform's client. Accepting the whole
    set rather than a single value is what lets one API serve the Mac app and the web
    dashboard; accepting *anything* would let a token minted for somebody else's
    Google project through.
    """

    google_issuers: frozenset[str]
    google_jwks_url: str

    google_allowed_hosted_domain: str | None
    """Restrict sign-in to one Google Workspace domain, by the `hd` claim. None
    accepts any Google account, including personal ones, which carry no `hd`."""

    session_private_key_pem: str
    """PEM of the P-256 key this API signs its own access tokens with."""
    session_issuer: str
    access_token_ttl: float
    refresh_token_ttl: float
    refresh_token_reuse_interval: float
    """Seconds during which the refresh token just replaced may be exchanged again
    without reading as theft. Supabase's SECURITY_REFRESH_TOKEN_REUSE_INTERVAL, with its
    default; zero restores the strict rule."""

    database_url: str
    """The restricted login. Not the migration credential: this one is subject to
    row-level security, which is the entire reason it exists."""

    database_tls: bool
    """Whether to encrypt the database connection at all.

    Defaults to requiring it. The compose database, like the development one, is a
    container on a private network and offers no TLS, and this used to be inferred from the hostname being
    `localhost` — which is wrong the moment that database is a container reached by
    name, the ordinary way to run one.
    """

    database_ca_certificate_path: str | None
    """PEM of the CA that signed the database server's certificate.

    Required whenever TLS is on: a hosted Postgres usually signs with its own CA
    rather than a publicly-trusted one, and an encrypted connection to a server
    nothing has authenticated is refused at boot.
    """

    resend_api_key: str
    """Resend, which carries the sign-up code.

    Required rather than optional, deliberately. Sign-up cannot complete without
    mail, so a deployment missing these is broken — and it is far better to learn
    that at boot than from the first person who tries to make an account and never
    receives anything.
    """
    resend_from: str
    """The `From` header, e.g. `Deylee <no-reply@deylee.app>`. The domain has to be
    verified in Resend or every send is refused."""
    resend_otp_template_id: str
    """Id or alias of the published template. It takes one variable, `otp`."""

    signup_code_ttl: int
    signup_code_resend_cooldown: int
    """How long before another code may be sent to the same address. Without it the
    endpoint is a free way to post mail to a stranger's inbox."""

    port: int

    host: str
    """The address to bind.

    Loopback by default, so a development run is not quietly serving the whole local
    network. A container must set HOST=0.0.0.0 or nothing outside it can reach the
    process — the platform's health check fails, the deploy is marked bad, and the
    logs say only that the server started.
    """

    web_origins: frozenset[str]
    """Browser origins allowed to call the API cross-origin, for `/v1/contact`.

    The marketing site is a static export on another host, so its contact form is a
    cross-origin POST and a browser will not send one without this. Nothing else needs
    it: the Mac app is not a browser and never asks.

    An allow-list rather than `*`, and paired with credentials off, so this grants the
    site the ability to post a form and grants nobody the ability to ride somebody's
    session. Comma-separated, for running the site locally against a local API.
    """

    updates_directory: str | None
    """Where the update feed and its archives are read from, or None to serve none.

    A directory rather than anything baked into the image, so publishing a release is
    copying two files into a mounted volume — not rebuilding and redeploying the API
    to ship a new version of the Mac app. Unset in development, where there is
    nothing to serve and the route should simply not exist.
    """


class ConfigError(Exception):
    """Refusal to start. `str(e)` is the sentence the operator reads in the logs."""

    @classmethod
    def missing(cls, key: str) -> ConfigError:
        return cls(f"{key} is not set. Copy .env.example to .env and fill it in.")

    @classmethod
    def malformed(cls, key: str, reason: str) -> ConfigError:
        return cls(f"{key} is malformed: {reason}")


def load_config(lookup: Lookup = os.environ.get) -> Config:
    """Build from a variable lookup, defaulting to the process environment.

    The lookup is a parameter so tests can supply a dictionary instead of mutating
    the environment of the process running them.
    """

    # Both trim. A value copied out of a dashboard often arrives with a trailing
    # space or newline attached, and an untrimmed client id is worse than a missing
    # one: it looks configured, passes every startup check, and then silently matches
    # no token Google will ever issue.
    def optional(key: str) -> str | None:
        raw = lookup(key)
        if raw is None:
            return None
        value = raw.strip()
        return value or None

    def required(key: str) -> str:
        value = optional(key)
        if value is None:
            raise ConfigError.missing(key)
        return value

    def integer(key: str, default: int) -> int:
        """Unset *or unparsable* falls back, matching Swift's `flatMap(Int.init)`."""
        value = optional(key)
        if value is None:
            return default
        try:
            return int(value)
        except ValueError:
            return default

    # Every client id that is actually configured becomes an accepted audience. Empty
    # ones are platforms that do not exist yet, and an empty string must never end up
    # in the set — it would match a token with no `aud` at all.
    audiences = {
        value
        for key in (
            "GOOGLE_CLIENT_ID_IOS",
            "GOOGLE_CLIENT_ID_WEB",
            "GOOGLE_CLIENT_ID_ANDROID",
            "GOOGLE_CLIENT_ID_DESKTOP",
        )
        if (value := optional(key)) is not None
    }
    if not audiences:
        raise ConfigError.missing("GOOGLE_CLIENT_ID_* (at least one)")

    jwks_url = optional("GOOGLE_JWKS_URL") or "https://www.googleapis.com/oauth2/v3/certs"
    # Swift's URL(string:) also accepted relative strings; httpx would only reject one
    # at the first key fetch, hours in. Demand an absolute URL at boot instead.
    try:
        parts = urlsplit(jwks_url)
    except ValueError as error:
        raise ConfigError.malformed("GOOGLE_JWKS_URL", "not a URL") from error
    if not parts.scheme or not parts.netloc:
        raise ConfigError.malformed("GOOGLE_JWKS_URL", "not a URL")

    # Google is inconsistent about the scheme in the `iss` claim it issues, and both
    # spellings are legitimate. A verifier that knows only one rejects perfectly valid
    # tokens, seemingly at random.
    issuer = optional("GOOGLE_ISSUER") or "https://accounts.google.com"

    return Config(
        google_audiences=frozenset(audiences),
        google_issuers=frozenset({issuer, issuer.replace("https://", "")}),
        google_jwks_url=jwks_url,
        google_allowed_hosted_domain=optional("GOOGLE_ALLOWED_HD"),
        session_private_key_pem=_decode_base64_pem(
            required("SESSION_JWT_PRIVATE_KEY_B64"), "SESSION_JWT_PRIVATE_KEY_B64"
        ),
        session_issuer=optional("SESSION_JWT_ISSUER") or "https://api.deylee.app",
        access_token_ttl=float(integer("ACCESS_TOKEN_TTL_SECONDS", 3600)),
        refresh_token_ttl=float(integer("REFRESH_TOKEN_TTL_DAYS", 90) * 86_400),
        refresh_token_reuse_interval=float(integer("REFRESH_TOKEN_REUSE_INTERVAL_SECONDS", 10)),
        database_url=required("DEYLEE_DB_URL"),
        database_tls=(optional("DEYLEE_DB_TLS") or "require").lower() != "disable",
        database_ca_certificate_path=optional("DEYLEE_DB_CA_CERT"),
        resend_api_key=required("RESEND_API_KEY"),
        resend_from=required("RESEND_FROM"),
        resend_otp_template_id=required("RESEND_OTP_TEMPLATE_ID"),
        # Ten minutes is long enough to find the mail in a spam folder and short
        # enough that a code left on a screen is not a standing key.
        signup_code_ttl=integer("SIGNUP_CODE_TTL_SECONDS", 600),
        signup_code_resend_cooldown=integer("SIGNUP_CODE_RESEND_SECONDS", 60),
        port=integer("PORT", 8080),
        host=optional("HOST") or "127.0.0.1",
        # Defaulted rather than required: the site is deployed and its form has to work,
        # and a deployment that forgot this would fail only in a browser's console.
        web_origins=frozenset(
            origin
            for raw in (optional("WEB_ORIGIN") or "https://deylee.faizraza.me").split(",")
            if (origin := raw.strip())
        ),
        updates_directory=optional("DEYLEE_UPDATES_DIR"),
    )


def _decode_base64_pem(encoded: str, key: str) -> str:
    # validate=False discards anything outside the base64 alphabet, matching Swift's
    # .ignoreUnknownCharacters — which is what lets a wrapped, newline-laden value
    # through. Pasting the PEM in unencoded still fails, here or on the -----BEGIN
    # check below, and that is the mistake this guard exists for.
    try:
        pem = base64.b64decode(encoded, validate=False).decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError) as error:
        raise ConfigError.malformed(key, "not base64-encoded UTF-8") from error
    if "-----BEGIN" not in pem:
        raise ConfigError.malformed(key, "decoded value is not PEM")
    return pem


def dotenv_read(path: str) -> dict[str, str]:
    """Load `.env` into a dictionary, for local runs.

    Deliberately not applied to the process environment: a real deployment injects
    variables itself, and a file quietly overriding those would be the kind of bug
    that only shows up once, in production, at the worst moment.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return {}

    out: dict[str, str] = {}
    for line in text.split("\n"):
        trimmed = line.strip()
        if not trimmed or trimmed.startswith("#") or "=" not in trimmed:
            continue
        # First '=' only. Splitting on every one would truncate exactly the
        # connection strings this file exists to carry.
        name, _, value = trimmed.partition("=")
        name = name.strip()
        if name:
            out[name] = value.strip()
    return out


def dotenv_merged(path: str) -> Lookup:
    """The process environment wins over the file, never the other way round."""
    file = dotenv_read(path)

    def lookup(key: str) -> str | None:
        # An empty process value counts as absent, so an injected blank does not
        # shadow a working default in the file.
        return os.environ.get(key) or file.get(key)

    return lookup

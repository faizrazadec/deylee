"""Configuration is read once at boot and never again, so a mistake here is a process
that starts happily and is wrong for its whole lifetime. These pin the refusals — the
cases where refusing to start is the correct behaviour.
"""

import base64

import pytest
from conftest import TEST_PRIVATE_KEY_PEM, load_env, valid_env

from deylee_api.config import ConfigError, dotenv_merged, dotenv_read
from deylee_api.tokens import RefreshToken

# --------------------------------------------------------------------- loading


def test_loads_a_minimal_valid_environment():
    config = load_env(valid_env())
    assert config.google_audiences == frozenset({"111-ios.apps.googleusercontent.com"})
    assert config.port == 8080
    assert config.access_token_ttl == 3600
    assert config.refresh_token_ttl == 90 * 86_400
    assert config.google_allowed_hosted_domain is None


def test_collects_every_configured_client_id_and_skips_blank_ones():
    """Every configured client id is an accepted audience; the platforms that do not
    exist yet are blank and must not become one."""
    config = load_env(
        valid_env(
            GOOGLE_CLIENT_ID_WEB="222-web.apps.googleusercontent.com",
            GOOGLE_CLIENT_ID_ANDROID="",
            GOOGLE_CLIENT_ID_DESKTOP="   ",
        )
    )
    assert len(config.google_audiences) == 2
    assert "222-web.apps.googleusercontent.com" in config.google_audiences
    # An empty string in the set would match a token carrying no `aud` at all.
    assert "" not in config.google_audiences


def test_refuses_to_start_with_no_google_client_at_all():
    """An empty audience set would mean every token is refused, which looks like a broken
    sign-in rather than a misconfiguration. Refuse to start instead."""
    env = valid_env()
    del env["GOOGLE_CLIENT_ID_IOS"]
    with pytest.raises(ConfigError):
        load_env(env)


@pytest.mark.parametrize("key", ["SESSION_JWT_PRIVATE_KEY_B64", "DEYLEE_DB_URL"])
def test_refuses_to_start_without_a_signing_key_or_a_database(key):
    env = valid_env()
    del env[key]
    with pytest.raises(ConfigError):
        load_env(env)


@pytest.mark.parametrize("key", ["RESEND_API_KEY", "RESEND_FROM", "RESEND_OTP_TEMPLATE_ID"])
def test_refuses_to_start_without_mail_credentials(key):
    """Sign-up mails a code before it creates anything, so a deployment that cannot send
    is one where nobody can make an account. Better to refuse at boot than to discover it
    from the first person who tries."""
    env = valid_env()
    del env[key]
    with pytest.raises(ConfigError):
        load_env(env)


def test_code_timings_default_and_can_be_tuned():
    """The code lifetime and the resend cooldown have working defaults, so only the three
    credentials are mandatory."""
    config = load_env(valid_env())
    assert config.signup_code_ttl == 600
    assert config.signup_code_resend_cooldown == 60

    tuned = load_env(valid_env(SIGNUP_CODE_TTL_SECONDS="300", SIGNUP_CODE_RESEND_SECONDS="90"))
    assert tuned.signup_code_ttl == 300
    assert tuned.signup_code_resend_cooldown == 90


@pytest.mark.parametrize(
    "value",
    [
        pytest.param(TEST_PRIVATE_KEY_PEM, id="raw-pem"),
        pytest.param(base64.b64encode(b"not a pem").decode(), id="base64-of-not-a-pem"),
    ],
)
def test_rejects_a_signing_key_that_is_not_base64_pem(value):
    """Pasting the PEM in directly rather than base64-encoding it is the obvious mistake,
    and it must not be mistaken for a key."""
    with pytest.raises(ConfigError):
        load_env(valid_env(SESSION_JWT_PRIVATE_KEY_B64=value))


def test_accepts_both_spellings_of_googles_issuer():
    """Google issues `iss` both with and without the scheme, and both are correct.
    Accepting only one rejects valid tokens seemingly at random."""
    config = load_env(valid_env())
    assert "https://accounts.google.com" in config.google_issuers
    assert "accounts.google.com" in config.google_issuers


def test_carries_a_hosted_domain_restriction_when_set():
    config = load_env(valid_env(GOOGLE_ALLOWED_HD="snapdev.ai"))
    assert config.google_allowed_hosted_domain == "snapdev.ai"


# ---------------------------------------------------------------------- dotenv


def test_reads_pairs_and_ignores_comments_and_blanks(tmp_path):
    path = tmp_path / "dotenv"
    path.write_text(
        "# a comment\n"
        "KEY_A=value-a\n"
        "\n"
        "KEY_B = value-b\n"
        "# KEY_C=commented-out\n"
        "URL=postgresql://u:p@host:5432/db?x=1\n",
        encoding="utf-8",
    )

    env = dotenv_read(str(path))
    assert env["KEY_A"] == "value-a"
    assert env["KEY_B"] == "value-b"
    assert "KEY_C" not in env
    # A value containing '=' must survive intact; splitting on every '=' would truncate
    # exactly the connection strings this file exists to carry.
    assert env["URL"] == "postgresql://u:p@host:5432/db?x=1"


def test_missing_file_is_empty_rather_than_fatal(tmp_path):
    assert dotenv_read(str(tmp_path / "nothing-here")) == {}


def test_the_process_environment_wins_over_the_file(tmp_path, monkeypatch):
    """A real deployment injects its own variables, and a file quietly overriding those
    would be the kind of bug that shows up once, in production, at the worst moment.

    monkeypatch rather than a dict lookup because `dotenv_merged` reads `os.environ`
    itself — that is the behaviour under test — and monkeypatch puts it back afterwards.
    """
    path = tmp_path / "dotenv"
    path.write_text("FROM_FILE=file-value\nOVERRIDDEN=file-value\nBLANKED=file-value\n")

    monkeypatch.setenv("OVERRIDDEN", "process-value")
    # An injected blank counts as absent, so an empty variable in a deployment's
    # environment does not shadow a working value in the file.
    monkeypatch.setenv("BLANKED", "")

    lookup = dotenv_merged(str(path))
    assert lookup("OVERRIDDEN") == "process-value"
    assert lookup("FROM_FILE") == "file-value"
    assert lookup("BLANKED") == "file-value"
    assert lookup("SET_NOWHERE") is None


# --------------------------------------------------------------- refresh tokens


def test_digests_to_exactly_the_thirty_two_bytes_the_schema_demands():
    # The refresh_tokens table constrains octet_length(token_hash) = 32; a mismatch here
    # would surface as a check violation at sign-in.
    assert len(RefreshToken.digest(RefreshToken.generate())) == 32


def test_generates_a_distinct_token_each_time():
    tokens = [RefreshToken.generate() for _ in range(64)]
    assert len(set(tokens)) == 64


def test_digest_is_stable_for_the_same_token():
    token = RefreshToken.generate()
    assert RefreshToken.digest(token) == RefreshToken.digest(token)

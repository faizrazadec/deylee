"""What every suite here needs: a valid environment, and the database gate.

Nothing in this file touches `os.environ`. Configuration is read through a lookup the
caller supplies, so a test can state the environment it wants without mutating the one
the test runner is living in — which is the difference between a suite that can run in
any order and one that cannot.
"""

import base64
import os

import pytest

from deylee_api.config import Config, load_config

#: A throwaway P-256 key, generated for this suite and used nowhere else. It is the same
#: key the Swift suite carried, so a token minted by either implementation verifies in
#: the other and the compatibility tests mean something.
#:
#: Never paste a real signing key here: this file is committed, and a key in git is a key
#: that has to be rotated.
TEST_PRIVATE_KEY_PEM = """-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIC/YSqhru+TLD61OScLVoy6htoDsQryXDzXGXdjIUmcEoAoGCCqGSM49
AwEHoUQDQgAEB41OA3jk+wltDCzDvu/PWYxze0h8gN+Q7Ep+9L0We2ZnEHF+HBLB
vlOmJC+SQSE63eJsgexBvAyP3WpsriaSFw==
-----END EC PRIVATE KEY-----
"""


def valid_env(**overrides: str) -> dict[str, str]:
    """A minimal environment `load_config` accepts, as a dictionary."""
    env = {
        "GOOGLE_CLIENT_ID_IOS": "111-ios.apps.googleusercontent.com",
        "SESSION_JWT_PRIVATE_KEY_B64": base64.b64encode(TEST_PRIVATE_KEY_PEM.encode()).decode(),
        "DEYLEE_DB_URL": "postgresql://user:pw@localhost:5432/postgres",
        # Sign-up cannot complete without mail, so these are required too.
        "RESEND_API_KEY": "re_test_key",
        "RESEND_FROM": "Deylee <no-reply@example.test>",
        "RESEND_OTP_TEMPLATE_ID": "tmpl_test",
    }
    env.update(overrides)
    return env


def load_env(env: dict[str, str]) -> Config:
    return load_config(env.get)


#: The restricted login, or None. `./scripts/dev-db.sh` builds exactly the right thing —
#: the production schema in a throwaway container — and prints the URL.
#:
#: **It must be the restricted login, not the owner.** Connecting as `postgres` makes
#: every tenancy assertion pass while proving nothing, because policies do not apply to a
#: superuser.
TEST_DB_URL = os.environ.get("DEYLEE_TEST_DB_URL")

requires_db = pytest.mark.skipif(TEST_DB_URL is None, reason="set DEYLEE_TEST_DB_URL to run")

#: The owner login, or None. Only for reading tables the API role deliberately cannot —
#: `contact_requests` and `feedback` are append-only by having no grant at all, so the
#: restricted role cannot check what a route actually wrote.
#:
#: Separate from TEST_DB_URL rather than replacing it, because a suite that connected as
#: the owner throughout would pass every tenancy assertion while proving nothing.
#: `./scripts/dev-db.sh` prints both.
TEST_DB_OWNER_URL = os.environ.get("DEYLEE_TEST_DB_OWNER_URL")

requires_owner_db = pytest.mark.skipif(
    TEST_DB_OWNER_URL is None, reason="set DEYLEE_TEST_DB_OWNER_URL to read append-only tables"
)

"""Settings sync through the route a client uses: last write wins, one row per person,
nobody else's row visible, and a malformed set refused before it reaches the table.

Connected as the restricted role, like the API, with a fresh account per test.
"""

import logging
import time
from collections.abc import AsyncIterator
from uuid import uuid4

import httpx
import pytest
from conftest import TEST_DB_URL, load_env, requires_db, valid_env
from fastapi import FastAPI

from deylee_api.app import create_app
from deylee_api.db import Store
from deylee_api.mail import Mailer
from deylee_api.ratelimit import RateLimiter
from deylee_api.tokens import TokenService

pytestmark = requires_db
LOGGER = logging.getLogger("settings-test")


def now_ms() -> int:
    return int(time.time() * 1000)


@pytest.fixture
async def store() -> AsyncIterator[Store]:
    assert TEST_DB_URL is not None
    store = Store(TEST_DB_URL, tls=False, ca_certificate_path=None, logger=LOGGER)
    await store.start()
    try:
        yield store
    finally:
        await store.close()


@pytest.fixture
async def app(store: Store) -> FastAPI:
    config = load_env(valid_env())
    return create_app(
        config=config,
        store=store,
        tokens=TokenService(config),
        mailer=Mailer(
            api_key=config.resend_api_key,
            sender=config.resend_from,
            template_id=config.resend_otp_template_id,
            logger=LOGGER,
        ),
        limiter=RateLimiter(),
        logger=LOGGER,
        assert_rls=False,
    )


@pytest.fixture
async def client(app: FastAPI) -> AsyncIterator[httpx.AsyncClient]:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


async def sign_in(app: FastAPI, store: Store) -> dict[str, str]:
    async with store.without_tenant() as connection:
        subject = f"settings-{uuid4()}"
        user = await connection.fetchval(
            "SELECT id FROM public.auth_sign_in_with_google($1, $2, true, 'Probe', 'UTC')",
            subject,
            f"{subject}@settings.invalid",
        )
    token = await app.state.tokens.issue_access_token(user, uuid4())
    return {"Authorization": f"Bearer {token}"}


async def call(client: httpx.AsyncClient, headers: dict[str, str], body: dict) -> httpx.Response:
    return await client.post("/v1/settings", json=body, headers=headers)


async def test_an_account_with_no_settings_reads_as_none(app, store, client):
    headers = await sign_in(app, store)
    response = await call(client, headers, {})
    assert response.status_code == 200
    assert response.json()["settings"] is None
    assert response.json()["updatedAt"] is None


async def test_a_pushed_set_is_what_the_next_read_returns(app, store, client):
    headers = await sign_in(app, store)
    at = now_ms()
    pushed = {"theme": "dark", "idleThresholdMinutes": 15, "keepAwakeLidClosed": True}
    assert (await call(client, headers, {"settings": pushed, "updatedAt": at})).status_code == 200

    read = (await call(client, headers, {})).json()
    assert read["settings"] == pushed
    assert read["updatedAt"] == at


async def test_an_older_set_loses_and_the_winner_comes_back(app, store, client):
    headers = await sign_in(app, store)
    at = now_ms()
    await call(client, headers, {"settings": {"theme": "dark"}, "updatedAt": at})

    stale = (
        await call(client, headers, {"settings": {"theme": "light"}, "updatedAt": at - 1})
    ).json()
    assert stale["settings"] == {"theme": "dark"}
    assert stale["updatedAt"] == at

    replay = (await call(client, headers, {"settings": {"theme": "light"}, "updatedAt": at})).json()
    assert replay["settings"] == {"theme": "dark"}, "an equal updatedAt is a no-op"

    newer = (
        await call(client, headers, {"settings": {"theme": "light"}, "updatedAt": at + 1})
    ).json()
    assert newer["settings"] == {"theme": "light"}


async def test_one_person_never_reads_another_persons_settings(app, store, client):
    owner = await sign_in(app, store)
    stranger = await sign_in(app, store)
    await call(client, owner, {"settings": {"theme": "dark"}, "updatedAt": now_ms()})

    assert (await call(client, stranger, {})).json()["settings"] is None


@pytest.mark.parametrize(
    "body",
    [
        {"settings": {"theme": {"nested": True}}, "updatedAt": 1},
        {"settings": {"theme": ["dark"]}, "updatedAt": 1},
        {"settings": {"theme": "x" * 65}, "updatedAt": 1},
        {"settings": {f"k{i}": True for i in range(65)}, "updatedAt": 1},
        {"settings": {"theme": "dark"}},
        {"updatedAt": 1},
        {"settings": {"theme": "dark"}, "updatedAt": 10**15},
    ],
)
async def test_a_malformed_or_future_set_is_refused(app, store, client, body):
    headers = await sign_in(app, store)
    response = await call(client, headers, body)
    assert response.status_code == 400, response.text
    assert (await call(client, headers, {})).json()["settings"] is None


async def test_no_token_no_settings(client):
    response = await client.post("/v1/settings", json={})
    assert response.status_code == 401

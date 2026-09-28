"""POST /v1/settings: a person's preferences, kept so a new or wiped install gets them back.

One round trip for push and pull, like /v1/sync. A body with `settings` and `updatedAt`
proposes a version; a body without them only reads. Either way the answer is the stored
winner, so a client that lost learns what won in the same request.

The server knows the shape of a preference set, not its meaning: keys and scalar values,
bounded. Every client clamps each key it reads, so an out-of-range value stored here costs
that key its default on the far side and nothing more.
"""

import json
import math
import time
from typing import Any

from fastapi import APIRouter, Request
from pydantic import BaseModel

from deylee_api.errors import APIError
from deylee_api.routes.sync import _authenticate, claims_the_future

router = APIRouter()

MAX_KEYS = 64
MAX_KEY_LENGTH = 64
MAX_STRING_LENGTH = 64


class SettingsRequest(BaseModel):
    settings: dict[str, Any] | None = None
    updatedAt: int | None = None


def settings_problem(settings: dict[str, Any]) -> str | None:
    """Why a proposed set is refused, or None. Scalars only: a nested object or a list
    is not a preference, and a NaN is not a number jsonb will store."""
    if len(settings) > MAX_KEYS:
        return f"At most {MAX_KEYS} settings."
    for key, value in settings.items():
        if not key or len(key) > MAX_KEY_LENGTH:
            return "A setting's name is empty or too long."
        if isinstance(value, bool):
            continue
        if isinstance(value, int | float):
            if not math.isfinite(value):
                return f"`{key}` is not a finite number."
            continue
        if isinstance(value, str):
            if len(value) > MAX_STRING_LENGTH:
                return f"`{key}` is too long."
            continue
        return f"`{key}` must be a boolean, a number or a string."
    return None


@router.post("/v1/settings")
async def sync_settings(request: Request, body: SettingsRequest) -> dict[str, Any]:
    user_id = await _authenticate(request)
    now = int(time.time() * 1000)

    if (body.settings is None) != (body.updatedAt is None):
        raise APIError(400, "`settings` and `updatedAt` are sent together or not at all.")
    if body.settings is not None and body.updatedAt is not None:
        problem = settings_problem(body.settings)
        if problem is not None:
            raise APIError(400, problem)
        # The same bound segments get: a clock set years ahead would otherwise win every
        # comparison for ever and freeze the person's settings on every other device.
        if claims_the_future(body.updatedAt, now):
            raise APIError(400, "`updatedAt` is in the future by this server's clock.")

    async with request.app.state.store.with_user(user_id) as connection:
        if body.settings is not None:
            # The owner is the transaction's tenant, never anything in the body. Strictly
            # newer wins; an equal `updated_at` is a replay and leaves the row alone.
            await connection.execute(
                """
                insert into public.user_settings (user_id, settings, updated_at)
                values (public.current_app_user(), $1::jsonb, $2)
                on conflict (user_id) do update
                  set settings = excluded.settings, updated_at = excluded.updated_at
                  where public.user_settings.updated_at < excluded.updated_at
                """,
                json.dumps(body.settings),
                body.updatedAt,
            )
        row = await connection.fetchrow(
            "select settings::text as settings, updated_at from public.user_settings"
        )

    return {
        "settings": json.loads(row["settings"]) if row else None,
        "updatedAt": row["updated_at"] if row else None,
        "serverTime": now,
    }

"""The heartbeat: a running timer saying "still here", stamped with the server's clock
on arrival.

The endpoint deliberately learns nothing from the request beyond who sent it and from
which device. No timestamp is accepted — the whole point is that a beat can only be
recorded in the present, so hours "witnessed" cannot be manufactured after the fact by
anything, including a stolen token. The reply says whether a row was written, which the
client only uses to avoid logging noise; a beat inside the server's dedup floor is a
success, not an error.
"""

import json
from uuid import UUID

from fastapi import APIRouter, Request

from deylee_api.errors import APIError
from deylee_api.tokens import TokenError

router = APIRouter()


@router.post("/v1/beat")
async def beat(request: Request) -> dict[str, bool]:
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        raise APIError(401, "A bearer token is required.")
    try:
        claims = await request.app.state.tokens.verify_access_token(header.removeprefix("Bearer "))
        user_id = UUID(claims.sub)
    except (TokenError, ValueError) as error:
        raise APIError(401, "A bearer token is required.") from error

    device_id = _device_id(await request.body())

    # Through the tenancy-scoped path like every other user write: the SECURITY DEFINER
    # function reads app.user_id itself, so even this route cannot vouch for a different
    # user than the token names.
    async with request.app.state.store.with_user(user_id) as connection:
        recorded = await connection.fetchval("SELECT public.record_witness_beat($1)", device_id)
    return {"recorded": bool(recorded)}


def _device_id(body: bytes) -> UUID | None:
    """The device id, or None for any body that does not plainly carry one.

    A missing, empty or unparseable body is not an error: clients that send none are
    already in the field, and the beat is worth recording without knowing the device.
    """
    try:
        decoded = json.loads(body)
        return UUID(decoded["deviceId"])
    except ValueError, TypeError, AttributeError, KeyError:
        return None

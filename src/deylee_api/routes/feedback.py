"""Feedback the user typed and pressed send on.

Authenticated, and deliberately so. Anonymous feedback cannot be answered and cannot be
rate limited honestly, so an account is the price of the button — the same account the
app already requires before a day can be started.

The route learns nothing the request does not carry: no IP is stored, no header is kept,
and the only fields written are the text, the app version and the OS string. The author
comes from the token by way of the tenancy-scoped path, never from the body, so a request
cannot file feedback as somebody else.
"""

import json
from uuid import UUID

from fastapi import APIRouter, Request

from deylee_api.errors import APIError
from deylee_api.tokens import TokenError

router = APIRouter()

#: The client's limit is 4000 characters and so is the column's. This one is the wire's,
#: sized to refuse an obviously absurd body before it reaches the database rather than
#: after.
MAXIMUM_BODY_BYTES = 8000


@router.post("/v1/feedback")
async def submit(request: Request) -> dict[str, bool]:
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        raise APIError(401, "A bearer token is required.")
    try:
        claims = await request.app.state.tokens.verify_access_token(header.removeprefix("Bearer "))
        user_id = UUID(claims.sub)
    except (TokenError, ValueError) as error:
        raise APIError(401, "A bearer token is required.") from error

    # Decoded here rather than through a request model, because FastAPI would answer a
    # malformed body with its own 422 and its own envelope, and the contract says 400
    # with this sentence.
    try:
        submission = json.loads(await request.body())
        body = submission["body"]
        app_version = submission.get("appVersion")
        os_version = submission.get("osVersion")
    except (ValueError, TypeError, AttributeError, KeyError) as error:
        raise APIError(400, "A feedback body is required.") from error
    if not isinstance(body, str) or not all(
        value is None or isinstance(value, str) for value in (app_version, os_version)
    ):
        raise APIError(400, "A feedback body is required.")

    text = body.strip()
    if not text:
        raise APIError(400, "Feedback cannot be empty.")
    if len(text.encode()) > MAXIMUM_BODY_BYTES:
        raise APIError(413, "That feedback is too long to send.")

    # Through the tenancy-scoped path like every other user write: the SECURITY DEFINER
    # function reads app.user_id itself, so this route cannot vouch for a different
    # author than the token names.
    async with request.app.state.store.with_user(user_id) as connection:
        accepted = await connection.fetchval(
            "SELECT public.submit_feedback($1, $2, $3)", text, app_version, os_version
        )

    # False is the hourly limit, not a failure to understand the request, and it is the
    # one refusal worth telling the user about in those words.
    if not accepted:
        raise APIError(429, "That is a lot of feedback in one hour. Try again later.")
    return {"accepted": True}

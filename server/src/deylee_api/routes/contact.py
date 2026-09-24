"""The Teams waitlist and the Enterprise enquiry, from the marketing site.

The one unauthenticated write in the API. Feedback can demand an account because the
person filing it already has one; a waitlist cannot, since the whole point is to hear
from people who have not signed up. That makes this the only route where a stranger can
put a row in the database, so it carries its own ceilings rather than relying on the
account that is not there:

* an IP allowance of its own, well under the global one, because the global limiter is
  sized for a syncing client and would let a script file thousands of these an hour;
* a per-address allowance inside the SECURITY DEFINER function, which is what stops one
  mailbox being used as a notepad — somebody with a fourth bug inside the hour has the
  app's own feedback window, which is authenticated and says so on the form;
* a body ceiling checked before the database is touched at all.

Nothing about the request is stored beyond what the form asks for. The IP is used to
meter and then dropped — it never reaches a column.
"""

import json

from fastapi import APIRouter, Request

from deylee_api.errors import APIError
from deylee_api.ratelimit import caller_of

router = APIRouter()

#: The three routes the form offers. Anything else is a client that has drifted from the
#: site. `fix` is a correction — a bug, or a claim on a page that does not hold.
KINDS = frozenset({"teams", "enterprise", "fix"})

#: The column's limit is 4000 characters. This one is the wire's, in bytes, sized to
#: refuse an obviously absurd body before it reaches the database rather than after —
#: 4000 characters of emoji is 16 KB of UTF-8, and that is still a legitimate message.
MAXIMUM_MESSAGE_BYTES = 20_000

#: Per IP, per hour. Generous for a person who mistypes their address twice and changes
#: their mind about the headcount; tedious for anything automated. Deliberately far below
#: the 600-per-minute the global limiter allows a syncing client.
IP_LIMIT = 10
IP_WINDOW_SECONDS = 3600.0


@router.post("/v1/contact")
async def submit(request: Request) -> dict[str, bool]:
    # Before the body is read, let alone the database opened: the cheapest possible
    # refusal for the caller this route exists to bound.
    limiter = request.app.state.limiter
    key = f"contact:{caller_of(request)}"
    retry_after = limiter.seconds_until_allowed(key, limit=IP_LIMIT, window=IP_WINDOW_SECONDS)
    if retry_after is not None:
        raise APIError(
            429,
            f"Too many messages. Try again in {retry_after} seconds.",
            {"Retry-After": str(retry_after)},
        )
    limiter.record(key, window=IP_WINDOW_SECONDS)

    # Decoded by hand rather than through a request model, because FastAPI would answer a
    # malformed body with its own 422 and its own envelope, and the contract says 400
    # with a sentence in `{"error":{"message":…}}`.
    try:
        submission = json.loads(await request.body())
        kind = submission["kind"]
        email = submission["email"]
        team_size = submission.get("teamSize")
        message = submission.get("message")
    except (ValueError, TypeError, AttributeError, KeyError) as error:
        raise APIError(400, "A kind and an email address are required.") from error

    if not isinstance(kind, str) or not isinstance(email, str):
        raise APIError(400, "A kind and an email address are required.")
    if not all(value is None or isinstance(value, str) for value in (team_size, message)):
        raise APIError(400, "A kind and an email address are required.")
    if kind not in KINDS:
        raise APIError(400, "That is not a kind of message this form sends.")

    address = email.strip()
    # The shape check is the database's, and it is the one that counts. This is here so an
    # obvious typo comes back as a sentence about the address rather than as a 500 from a
    # constraint — the rule is deliberately the same one, spelled the same way.
    if "@" not in address.strip("@") or " " in address or "." not in address.rsplit("@", 1)[-1]:
        raise APIError(400, "That does not look like an email address.")
    if len(address) > 320:
        raise APIError(400, "That does not look like an email address.")
    if message is not None and len(message.encode()) > MAXIMUM_MESSAGE_BYTES:
        raise APIError(413, "That message is too long to send.")

    # No tenancy to set: there is no user here, and the function takes nothing from the
    # session. It is granted to `deylee_api` and to nothing else, which is what keeps this
    # from being a general insert.
    async with request.app.state.store.without_tenant() as connection:
        accepted = await connection.fetchval(
            "SELECT public.submit_contact_request($1, $2, $3, $4)",
            kind,
            address,
            team_size,
            message,
        )

    # False is the per-address hourly allowance, not a failure to understand the request.
    if not accepted:
        raise APIError(429, "That address has sent a few of these already. Try again later.")
    return {"accepted": True}

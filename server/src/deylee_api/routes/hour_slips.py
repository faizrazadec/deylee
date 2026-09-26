"""Hour slips: a signed statement of claimed and witnessed hours, and its public check.

The person recorded asks for one (`POST /v1/hour-slips`) and chooses who sees it. The
hour slip is a token signed with a key used for nothing else; its QR code links to
`GET /slip/<token>`, which anybody holding the hour slip can open.

Nothing is stored. PRODUCT.md §6 refuses stored totals, and an hour slip does not need one:
the token carries the totals the server signed, and the check page re-derives them from
the segments and witness beats underneath, so it says both "the server issued this" and
"the record still says so". Only ended days can go on an hour_slip, because a locked day's
times cannot change — so an hour slip checks the same way for as long as the account exists.

What the page shows — name, full email address and the hours — is exactly what its
holder was handed. That is the point of it, and why only the person can create one.
"""

import html
import secrets
import time
from datetime import UTC, date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import jwt
from cryptography.hazmat.primitives.serialization import load_pem_private_key
from fastapi import APIRouter, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from starlette.responses import HTMLResponse

from deylee_api.errors import APIError
from deylee_api.tokens import TokenError

router = APIRouter()

#: The most days one hour slip covers.
MAX_DAYS = 30
#: In the token's header, so an hour slip can never be mistaken for any other token.
TOKEN_TYPE = "deylee-hour-slip"


class HourSlipRequest(BaseModel):
    #: Inclusive local dates, YYYY-MM-DD. `from` is a Python keyword, hence the alias.
    from_: str = Field(alias="from")
    to: str
    timeZone: str


class HourSlipDay(BaseModel):
    date: str
    claimedMs: int
    witnessedMs: int
    #: The day is old enough that only a UTC-day total of its witness beats survives.
    witnessedApproximate: bool


class HourSlipResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    url: str
    issuedAt: int
    name: str | None
    email: str
    from_: str = Field(alias="from")
    to: str
    timeZone: str
    claimedMs: int
    witnessedMs: int
    days: list[HourSlipDay]


@router.post("/v1/hour-slips")
async def create(request: Request) -> dict:
    state = request.app.state
    key = state.config.hour_slip_private_key_pem
    if key is None:
        raise APIError(503, "Hour slips are not set up on this server yet.")
    user_id = await _authenticate(request)

    try:
        body = HourSlipRequest.model_validate_json(await request.body())
    except ValidationError as error:
        raise APIError(400, "An hour slip needs from, to and timeZone.") from error
    first, last, zone = _period(body.from_, body.to, body.timeZone)

    async with state.store.with_user(user_id) as connection:
        await connection.execute("SELECT set_config('app.time_zone', $1, true)", zone.key)
        # Only days the server considers over: their times are final, so the hour slip
        # checks the same way for ever. The latest date decides for all of them.
        if not await connection.fetchval(
            "SELECT public.epoch_ms() >= public.day_lock_at($1, $2)", user_id, last.isoformat()
        ):
            raise APIError(400, "An hour slip can only cover days that have ended.")
        profile = await connection.fetchrow(
            "SELECT email, display_name FROM public.app_users WHERE id = $1", user_id
        )
        days = await _days(connection, first, last, zone)

    claimed = sum(day.claimedMs for day in days)
    witnessed = sum(day.witnessedMs for day in days)
    issued_at = int(time.time())
    token = jwt.encode(
        {
            "sub": str(user_id),
            "tz": zone.key,
            "from": first.isoformat(),
            "to": last.isoformat(),
            "claimed": claimed,
            "witnessed": witnessed,
            "iat": issued_at,
            "jti": secrets.token_hex(8),
        },
        key,
        algorithm="ES256",
        headers={"typ": TOKEN_TYPE},
    )
    base = state.config.public_base_url or str(request.base_url).rstrip("/")
    return HourSlipResponse(
        url=f"{base}/slip/{token}",
        issuedAt=issued_at * 1000,
        name=profile["display_name"],
        email=profile["email"],
        from_=first.isoformat(),
        to=last.isoformat(),
        timeZone=zone.key,
        claimedMs=claimed,
        witnessedMs=witnessed,
        days=days,
    ).model_dump(by_alias=True)


@router.get("/slip/{token}", response_class=HTMLResponse)
async def check(request: Request, token: str) -> HTMLResponse:
    state = request.app.state
    key = state.config.hour_slip_private_key_pem
    if key is None:
        return _page("Hour slips are not set up on this server", None, status=503)
    try:
        public = load_pem_private_key(key.encode(), password=None).public_key()
        if jwt.get_unverified_header(token).get("typ") != TOKEN_TYPE:
            raise jwt.InvalidTokenError("not an hour slip")
        claims = jwt.decode(
            token, public, algorithms=["ES256"],
            options={"require": ["sub", "tz", "from", "to", "claimed", "witnessed", "iat"],
                     "verify_exp": False},
        )
        user_id = UUID(claims["sub"])
        first, last, zone = _period(claims["from"], claims["to"], claims["tz"])
    except (jwt.InvalidTokenError, ValueError, KeyError, APIError):
        return _page("This is not a valid Deylee hour slip", None, status=404)

    # Scoped to the person the signature names: the token is the authority for whose
    # record is read, exactly as a bearer token is for the other routes.
    async with state.store.with_user(user_id) as connection:
        profile = await connection.fetchrow(
            "SELECT email, display_name FROM public.app_users WHERE id = $1", user_id
        )
        days = await _days(connection, first, last, zone) if profile else []
    if profile is None:
        return _page("This hour slip's account no longer exists", None, status=410)
    return _page("Verified Deylee hour slip", {
        "claims": claims, "profile": profile, "days": days, "first": first, "last": last,
        "zone": zone,
    })


# MARK: Internals


async def _authenticate(request: Request) -> UUID:
    header = request.headers.get("authorization", "")
    if not header.startswith("Bearer "):
        raise APIError(401, "A bearer token is required.")
    try:
        claims = await request.app.state.tokens.verify_access_token(header.removeprefix("Bearer "))
        return UUID(claims.sub)
    except (TokenError, ValueError) as error:
        raise APIError(401, "That access token is not valid.") from error


def _period(first: str, last: str, zone_name: str) -> tuple[date, date, ZoneInfo]:
    try:
        start, end = date.fromisoformat(first), date.fromisoformat(last)
    except ValueError as error:
        raise APIError(400, "Dates must be YYYY-MM-DD.") from error
    try:
        zone = ZoneInfo(zone_name)
    except (ZoneInfoNotFoundError, ValueError) as error:
        raise APIError(400, "That time zone is not known.") from error
    if end < start:
        raise APIError(400, "An hour slip's last day cannot be before its first.")
    if (end - start).days + 1 > MAX_DAYS:
        raise APIError(400, f"An hour slip covers at most {MAX_DAYS} days.")
    return start, end, zone


def _day_window(day: date, zone: ZoneInfo) -> tuple[int, int]:
    """[start, end) of a local day in epoch ms, from calendar components in the zone —
    never start plus 86,400,000, which is an hour out either side of a clock change."""
    def instant(d: date) -> int:
        local = datetime(d.year, d.month, d.day, tzinfo=zone)
        # A midnight the clocks skip is resolved forwards, to the day's first real instant.
        return int(local.astimezone(UTC).timestamp() * 1000)

    return instant(day), instant(day + timedelta(days=1))


async def _days(connection, first: date, last: date, zone: ZoneInfo) -> list[HourSlipDay]:
    dates = [first + timedelta(days=n) for n in range((last - first).days + 1)]
    claimed = {
        row["day_date"]: int(row["ms"])
        for row in await connection.fetch(
            """
            SELECT day_date, sum(ended_at - started_at) AS ms
              FROM public.segments
             WHERE day_date = ANY($1::text[]) AND type = 'work'
               AND deleted_at IS NULL AND ended_at IS NOT NULL
             GROUP BY day_date
            """,
            [d.isoformat() for d in dates],
        )
    }
    days = []
    for d in dates:
        start, end = _day_window(d, zone)
        row = await connection.fetchrow(
            "SELECT * FROM public.hour_slip_witnessed($1, $2, $3)", start, end, d.isoformat()
        )
        days.append(HourSlipDay(
            date=d.isoformat(),
            claimedMs=claimed.get(d.isoformat(), 0),
            witnessedMs=int(row["witnessed_ms"]),
            witnessedApproximate=bool(row["approximate"]),
        ))
    return days


def _hm(ms: int) -> str:
    minutes = ms // 60000
    return f"{minutes // 60}h {minutes % 60:02d}m"


def _page(title: str, hour_slip: dict | None, status: int = 200) -> HTMLResponse:
    """The check page. Self-contained — no script, no external asset — so it renders the
    same in any browser a QR code opens, and cannot be made to load anything."""
    e = html.escape
    if hour_slip is None:
        body = f"<h1>{e(title)}</h1><p>Deylee could not confirm this link.</p>"
    else:
        claims, profile, days = hour_slip["claims"], hour_slip["profile"], hour_slip["days"]
        claimed_now = sum(d.claimedMs for d in days)
        witnessed_now = sum(d.witnessedMs for d in days)
        claimed_ok = claimed_now == claims["claimed"]
        witnessed_ok = witnessed_now == claims["witnessed"]
        issued = datetime.fromtimestamp(claims["iat"], UTC).strftime("%d %b %Y %H:%M UTC")
        rows = "".join(
            f"<tr><td>{e(d.date)}</td><td>{_hm(d.claimedMs)}</td>"
            f"<td>{_hm(d.witnessedMs)}{' *' if d.witnessedApproximate else ''}</td></tr>"
            for d in days
        )
        if claimed_ok and witnessed_ok:
            status_line = '<p class="ok">✓ Signed by Deylee, and the record still matches.</p>'
        elif claimed_ok:
            status_line = (
                '<p class="ok">✓ Signed by Deylee. Claimed hours match the record.</p>'
                '<p class="note">Witnessed time differs slightly from the signed total: old '
                "witness evidence is kept in less detail over time. The signed total is the "
                "one the server issued.</p>"
            )
        else:
            status_line = (
                '<p class="bad">Signed by Deylee, but the claimed hours no longer match '
                "the record.</p>"
            )
        approx = (
            '<p class="note">* Old enough that witnessed time is kept only as a UTC-day '
            "total, so this day's figure is approximate.</p>"
            if any(d.witnessedApproximate for d in days) else ""
        )
        body = f"""<h1>{e(title)}</h1>{status_line}
<dl><dt>Name</dt><dd>{e(profile["display_name"] or "—")}</dd>
<dt>Email</dt><dd>{e(profile["email"])}</dd>
<dt>Period</dt><dd>{e(hour_slip["first"].isoformat())} to {e(hour_slip["last"].isoformat())}
 ({e(hour_slip["zone"].key)})</dd>
<dt>Issued</dt><dd>{e(issued)}</dd>
<dt>Claimed work</dt><dd>{_hm(claims["claimed"])}</dd>
<dt>Witnessed live</dt><dd>{_hm(claims["witnessed"])}</dd></dl>
<table><tr><th>Day</th><th>Claimed</th><th>Witnessed</th></tr>{rows}</table>{approx}
<p class="note">Claimed is the work time recorded. Witnessed is time the server heard a
running timer, stamped by its own clock — it cannot be added afterwards.</p>"""
    return HTMLResponse(
        f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>{e(title)}</title><style>
body{{font:15px/1.5 -apple-system,system-ui,sans-serif;max-width:40rem;margin:2rem auto;
padding:0 1rem;color:#1d1d1f;background:#fff}}h1{{font-size:1.3rem}}
.ok{{color:#1a7f37;font-weight:600}}.bad{{color:#b3261e;font-weight:600}}
.note{{color:#6e6e73;font-size:.85rem}}dl{{display:grid;grid-template-columns:9rem 1fr;
gap:.2rem 1rem}}dt{{color:#6e6e73}}dd{{margin:0}}table{{border-collapse:collapse;
width:100%;margin-top:1rem}}td,th{{text-align:left;padding:.3rem .5rem;
border-bottom:1px solid #e5e5ea}}</style></head><body>{body}</body></html>""",
        status_code=status,
        headers={"Cache-Control": "no-store"},
    )

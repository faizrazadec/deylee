"""POST /v1/sync — push and pull in one round trip.

docs/SYNC_PROTOCOL.md is the binding contract, and a shipped client already speaks it:
the status codes, the per-row `code` vocabulary and the sentences below are not free to
change here. Push and pull share one request because a client with changes almost
always wants the other side's too, and splitting them doubles the latency for nothing.
"""

import contextlib
import time
from uuid import UUID

import asyncpg
from fastapi import APIRouter, Request
from pydantic import BaseModel, ValidationError

from deylee_api.errors import APIError
from deylee_api.tokens import TokenError

router = APIRouter()

#: Rows returned per response. A first sync of years of history is many round trips by
#: design; one request carrying all of it would time out.
PAGE_SIZE = 500
#: Changes accepted per push, matching the 413 in the protocol.
MAX_CHANGES_PER_PUSH = 500
#: Matching `segments_note_bounded` on the table and `maximumNoteLength` in the Mac app's
#: store, so a note is refused where it is typed rather than after a round trip.
#: Characters, as Postgres's `length()` counts them.
MAXIMUM_NOTE_LENGTH = 2000
#: How far ahead of the server a client's `updated_at` may be.
#:
#: Not zero, and not tight. Ordinary machines are minutes off without anybody having
#: done anything wrong, and refusing those rows would drop real work over a clock. Five
#: minutes admits every honest device and still bounds the damage a dishonest one can do
#: to five minutes of stuck row rather than for ever.
#:
#: The server deliberately does not *replace* the value — see the note in sync_core.sql.
#: Overwriting it would make every synced row look freshly edited and hand every conflict
#: to the staler device. Refusing an impossible claim is a different thing from rewriting
#: a plausible one.
FUTURE_TOLERANCE = 5 * 60 * 1000
PROTOCOL_VERSION = 1


# MARK: Wire types


class SyncRow(BaseModel):
    """One row, in the shape the protocol moves it.

    Fields not belonging to the table named alongside it are absent: `days` has `date`
    and `targetMinutes`, `segments` has `dayDate`, `type`, `startedAt` and `note`, and
    both use `endedAt`. A null is omitted on the way out rather than sent — the response
    is built with `exclude_none`, matching Swift's `encodeIfPresent`.
    """

    #: A string, not a UUID, and lower-cased on the way out.
    #:
    #: Postgres and the clients' SQLite stores both use lower case while Swift's
    #: UUID.uuidString is upper. Since a client upserts by this value into a
    #: case-SENSITIVE text index, echoing it back in the wrong case would insert a
    #: duplicate of every row it already held.
    id: str
    dayDate: str | None = None
    type: str | None = None
    startedAt: int | None = None
    endedAt: int | None = None
    note: str | None = None
    date: str | None = None
    targetMinutes: int | None = None
    createdAt: int | None = None
    updatedAt: int
    deletedAt: int | None = None
    #: Server-assigned, present only on rows coming back out.
    seq: int | None = None


class SyncChange(BaseModel):
    table: str
    op: str
    row: SyncRow


class SyncRequest(BaseModel):
    protocolVersion: int
    deviceId: UUID | None = None
    cursor: int
    changes: list[SyncChange]


class ChangeResult(BaseModel):
    id: str
    status: str
    code: str | None = None
    message: str | None = None


class SyncResponse(BaseModel):
    protocolVersion: int
    cursor: int
    serverTime: int
    hasMore: bool
    results: list[ChangeResult]
    changes: list[SyncChange]


# MARK: Route


# `response_model_exclude_none` is load-bearing, not tidiness: the clients decode a
# missing field and a null differently, and dropping it would put `"note": null` on rows
# that never had one.
@router.post("/v1/sync", response_model_exclude_none=True)
async def sync(request: Request) -> SyncResponse:
    state = request.app.state
    user_id = await _authenticate(request)

    try:
        body = SyncRequest.model_validate_json(await request.body())
    except ValidationError as error:
        # 400, never FastAPI's 422: the protocol spells a body the route cannot read as
        # a malformed request.
        raise APIError(400, "A sync body is required.") from error

    if body.protocolVersion != PROTOCOL_VERSION:
        raise APIError(400, f"Unsupported protocolVersion {body.protocolVersion}.")
    if len(body.changes) > MAX_CHANGES_PER_PUSH:
        raise APIError(413, f"At most {MAX_CHANGES_PER_PUSH} changes per push.")

    now = int(time.time() * 1000)

    # One transaction for push and pull together, holding the per-user advisory lock.
    # That lock is what makes the cursor trustworthy: sequence values are handed out at
    # write time but transactions commit out of order, so without serialising a user's
    # writes a pull can step past a row that has not committed yet and never come back
    # for it.
    async with state.store.with_user(user_id, lock_for_write=True) as connection:
        # A cursor past anything the server has ever issued means the client is talking
        # to a restored backup: the sequence rewound and every row it is asking for is
        # behind it. `WHERE seq > cursor` would match nothing, for ever, and the client
        # would go on pulling silently nothing at all.
        #
        # `pg_sequence_last_value` rather than `last_value`, which reports 1 on a
        # sequence never drawn from and would 409 the very first sync.
        highest = await connection.fetchval(
            "SELECT coalesce(pg_sequence_last_value('public.sync_seq'), 0)"
        )
        if body.cursor > highest:
            raise APIError(409, "That cursor is ahead of this server. Resync from zero.")

        results = [
            await _apply(connection, change, index, now=now, user_id=user_id)
            for index, change in enumerate(body.changes)
        ]
        pulled = await _pull(connection, cursor=body.cursor, user_id=user_id)

    has_more = len(pulled) > PAGE_SIZE
    if has_more:
        pulled = pulled[:PAGE_SIZE]

    return SyncResponse(
        protocolVersion=PROTOCOL_VERSION,
        cursor=pulled[-1].row.seq if pulled else body.cursor,
        serverTime=now,
        hasMore=has_more,
        results=results,
        changes=pulled,
    )


async def _authenticate(request: Request) -> UUID:
    header = request.headers.get("authorization")
    if header is None or not header.startswith("Bearer "):
        raise APIError(401, "A bearer token is required.")
    try:
        claims = await request.app.state.tokens.verify_access_token(header.removeprefix("Bearer "))
        return UUID(claims.sub)
    except (TokenError, ValueError) as error:
        # ValueError covers a token that verifies but carries a `sub` that is not a UUID.
        raise APIError(401, "That access token is not valid.") from error


def claims_the_future(updated_at: int, now: int) -> bool:
    """Whether a row's `updated_at` is further ahead of the server than honest skew
    explains.

    Swift saturated the bound because `Int64.max + tolerance` traps, and the value this
    exists to refuse is exactly `Int64.max`. Python's ints do not overflow, so the
    arithmetic is the whole check.
    """
    return updated_at > now + FUTURE_TOLERANCE


# MARK: Push


async def _apply(
    connection: asyncpg.Connection,
    change: SyncChange,
    index: int,
    *,
    now: int,
    user_id: UUID,
) -> ChangeResult:
    """Apply one change in its own savepoint.

    A rejection must not take the rest of the batch down with it. A client holding one
    corrupt row would otherwise be unable to sync anything, ever — the failure would be
    permanent and total rather than local to the row.

    The savepoint name comes from the row's position in the batch, which is unique by
    construction. It used to be a hash of the row id, which was wrong twice: `abs(Int.min)`
    trapped, taking the process down with every in-flight sync on it, and two ids
    colliding inside one batch produced the same name, so a release freed the earlier
    savepoint and a later rollback unwound a row that had already been applied.
    """
    # Refused before the savepoint, because an `updated_at` in the future is not a row
    # that failed — it is a row that would win every conflict from here on.
    # Last-write-wins compares the clients' own claims, so a claim of Int64.max makes the
    # row permanently uneditable on every device, with no way back through the app. A few
    # days of honest clock skew does the same thing quietly: corrections made on the right
    # machine lose to a stale row from the wrong one.
    if claims_the_future(change.row.updatedAt, now):
        return ChangeResult(
            id=change.row.id,
            status="rejected",
            code="invalid-shape",
            message="That row claims to have been edited in the future.",
        )

    # The one place SQL is built by formatting. The name is "sp_" and a loop index; no
    # part of it comes from the request.
    name = f"sp_{index}"
    try:
        await connection.execute(f"SAVEPOINT {name}")
        match (change.table, change.op):
            case ("segments", "upsert"):
                await _upsert_segment(connection, change.row, user_id)
            case ("segments", "delete"):
                await _tombstone(connection, "segments", change.row, user_id)
            case ("days", "upsert"):
                await _upsert_day(connection, change.row, user_id)
            case ("days", "delete"):
                await _tombstone(connection, "days", change.row, user_id)
            case _:
                raise APIError(400, f"Unknown {change.table}/{change.op}.")
        await connection.execute(f"RELEASE SAVEPOINT {name}")
        return ChangeResult(id=change.row.id, status="applied")
    except Exception as error:  # noqa: BLE001 — every refusal is a per-row rejection
        # Cancellation is a BaseException and so passes through: the request's deadline
        # must abandon the transaction, not be filed as a rejected row.
        with contextlib.suppress(Exception):
            await connection.execute(f"ROLLBACK TO SAVEPOINT {name}")
        code, message = classify(error)
        return ChangeResult(id=change.row.id, status="rejected", code=code, message=message)


def classify(error: Exception) -> tuple[str, str]:
    """Map a database refusal onto the protocol's vocabulary.

    These mirror MutationErrorCode in DeyleeKit so the Mac app can surface a server
    rejection through the path it already uses for a local one.
    """
    if isinstance(error, APIError):
        return ("invalid-shape", error.message)
    if isinstance(error, asyncpg.PostgresError):
        # `.message` is the server's own message field; `str` is the same text on a real
        # error and the only text on one constructed by hand, as the tests do.
        message = error.message or str(error)
        match error.sqlstate:
            case "23P01":
                # The exclusion constraint. Two open segments both run to infinity, so
                # this is also what "already running elsewhere" looks like.
                return ("overlap", "That time overlaps a segment already recorded.")
            case "23514":
                # The integrity bounds raise through this class on purpose — it is
                # already a per-row rejection, and never class 28 (see the
                # sign_in_error_code migration for what that class costs).
                if message == "in-the-future":
                    return ("invalid-shape", "That time has not happened yet.")
                if "segments_duration_sane" in message:
                    return ("invalid-shape", "A segment cannot be longer than sixteen hours.")
                return ("invalid-shape", "A field failed validation.")
            case "23503":
                return ("invalid-shape", "That row refers to something that does not exist.")
            case "23505":
                return ("stale", "A row with that identity already exists.")
            case _:
                return ("invalid-shape", message or str(error.sqlstate))
    return ("invalid-shape", str(error))


def _row_uuid(value: str) -> UUID:
    try:
        return UUID(value)
    except ValueError as error:
        raise APIError(400, "That id is not a UUID.") from error


# Last-write-wins, decided in the WHERE clause rather than by reading the row first:
# reading then writing would race with the other device's push even inside a transaction,
# and the comparison belongs where the write happens.
#
# Strictly greater, so an identical timestamp is a no-op. Replaying a push — which the
# protocol requires to be safe — therefore changes nothing.

_UPSERT_SEGMENT = """
    INSERT INTO public.segments
        (id, user_id, day_date, type, started_at, ended_at, note, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (id) DO UPDATE SET
        day_date   = EXCLUDED.day_date,
        type       = EXCLUDED.type,
        started_at = EXCLUDED.started_at,
        ended_at   = EXCLUDED.ended_at,
        note       = EXCLUDED.note,
        updated_at = EXCLUDED.updated_at
    WHERE EXCLUDED.updated_at > segments.updated_at
"""

_UPSERT_DAY = """
    INSERT INTO public.days
        (id, user_id, date, target_minutes, ended_at, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    ON CONFLICT (id) DO UPDATE SET
        date           = EXCLUDED.date,
        target_minutes = EXCLUDED.target_minutes,
        ended_at       = EXCLUDED.ended_at,
        updated_at     = EXCLUDED.updated_at
    WHERE EXCLUDED.updated_at > days.updated_at
"""

# A tombstone wins a tie, hence `>=`. Deletion is the conservative outcome: the row is
# still there and can be restored, whereas resurrecting time somebody deleted shows them
# hours they believed were gone. Two statements rather than one with the table name
# interpolated, because no request value belongs in SQL text.
_TOMBSTONE = {
    "segments": """
        UPDATE public.segments SET deleted_at = $1, updated_at = $1
        WHERE id = $2 AND user_id = $3 AND deleted_at IS NULL AND $1 >= updated_at
    """,
    "days": """
        UPDATE public.days SET deleted_at = $1, updated_at = $1
        WHERE id = $2 AND user_id = $3 AND deleted_at IS NULL AND $1 >= updated_at
    """,
}


async def _upsert_segment(connection: asyncpg.Connection, row: SyncRow, user_id: UUID) -> None:
    if row.dayDate is None or row.type is None or row.startedAt is None:
        raise APIError(400, "A segment needs dayDate, type and startedAt.")
    row_id = _row_uuid(row.id)
    # Checked here as well as by the CHECK on the table, so the refusal names the field.
    # Through the constraint it arrives as a generic "a field failed validation", which
    # tells the person who wrote the note nothing about which one or why. Characters,
    # matching `length(note)` in Postgres — not bytes.
    if row.note is not None and len(row.note) > MAXIMUM_NOTE_LENGTH:
        raise APIError(400, f"A note may be at most {MAXIMUM_NOTE_LENGTH} characters.")
    await connection.execute(
        _UPSERT_SEGMENT,
        row_id,
        user_id,
        row.dayDate,
        row.type,
        row.startedAt,
        row.endedAt,
        row.note,
        row.createdAt if row.createdAt is not None else row.updatedAt,
        row.updatedAt,
    )


async def _upsert_day(connection: asyncpg.Connection, row: SyncRow, user_id: UUID) -> None:
    if row.date is None or row.targetMinutes is None:
        raise APIError(400, "A day needs date and targetMinutes.")
    row_id = _row_uuid(row.id)
    await connection.execute(
        _UPSERT_DAY,
        row_id,
        user_id,
        row.date,
        row.targetMinutes,
        row.endedAt,
        row.createdAt if row.createdAt is not None else row.updatedAt,
        row.updatedAt,
    )


async def _tombstone(
    connection: asyncpg.Connection, table: str, row: SyncRow, user_id: UUID
) -> None:
    row_id = _row_uuid(row.id)
    await connection.execute(_TOMBSTONE[table], row.updatedAt, row_id, user_id)


# MARK: Pull

_PULL_SEGMENTS = """
    SELECT id, day_date, type, started_at, ended_at, note,
           created_at, updated_at, deleted_at, seq
    FROM public.segments WHERE user_id = $1 AND seq > $2
     ORDER BY seq LIMIT $3
"""

_PULL_DAYS = """
    SELECT id, date, target_minutes, ended_at, created_at, updated_at, deleted_at, seq
    FROM public.days WHERE user_id = $1 AND seq > $2
     ORDER BY seq LIMIT $3
"""


async def _pull(connection: asyncpg.Connection, *, cursor: int, user_id: UUID) -> list[SyncChange]:
    """Everything past the cursor, from both tables, in commit order.

    One extra row is fetched beyond the page so `hasMore` is known without a second count
    query.
    """
    limit = PAGE_SIZE + 1
    segments = await connection.fetch(_PULL_SEGMENTS, user_id, cursor, limit)
    days = await connection.fetch(_PULL_DAYS, user_id, cursor, limit)

    out = [
        SyncChange(
            table="segments",
            op="upsert" if row["deleted_at"] is None else "delete",
            row=SyncRow(
                id=str(row["id"]),
                dayDate=row["day_date"],
                type=row["type"],
                startedAt=row["started_at"],
                endedAt=row["ended_at"],
                note=row["note"],
                createdAt=row["created_at"],
                updatedAt=row["updated_at"],
                deletedAt=row["deleted_at"],
                seq=row["seq"],
            ),
        )
        for row in segments
    ]
    out += [
        SyncChange(
            table="days",
            op="upsert" if row["deleted_at"] is None else "delete",
            row=SyncRow(
                id=str(row["id"]),
                endedAt=row["ended_at"],
                date=row["date"],
                targetMinutes=row["target_minutes"],
                createdAt=row["created_at"],
                updatedAt=row["updated_at"],
                deletedAt=row["deleted_at"],
                seq=row["seq"],
            ),
        )
        for row in days
    ]

    # Interleaved by seq, because the two tables share one sequence and a client applying
    # them out of order would see a segment before its day.
    out.sort(key=lambda change: change.row.seq or 0)
    return out

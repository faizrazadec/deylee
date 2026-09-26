# Deylee — sync protocol

Binding specification for the wire contract between any Deylee client and the sync
API. macOS, iOS, Windows, Linux, Android, the web app and the browser extension all
implement *this document*, not each other. Where a client and this file disagree, the
file wins.

Companion documents: `MAC_APP_SPEC.md` for the macOS app's behaviour, and
`server/migrations/` for the storage schema this protocol moves rows into.

## Principles

**The client writes locally first, always.** A timer that stops working on a train is
worse than one that never synced at all. Every client keeps a local SQLite store, the
UI reads only from it, and sync is a background reconciliation. No user action ever
blocks on the network.

**The server is the authority on rules; the client is the authority on intent.** A
client proposes changes. The server validates them against the invariants — no
overlap, at most one open segment, sane ranges — and may refuse. Six client
implementations cannot be trusted to agree; one server can.

**Identifiers come from the client.** Two devices offline at the same moment must
create rows that cannot collide. Every id is a UUIDv7 generated where the row is
created. The server never mints one.

**Rows are tombstoned, never deleted.** A delete that fails to reach a sleeping
laptop resurrects the row on that machine's next sync.

**Totals are never transmitted.** They are derived by summing segments, on every
client, on every tick. A total on the wire is a second source of truth.

## Transport and authentication

    POST /v1/sync
    Authorization: Bearer <access token>
    Content-Type: application/json

One endpoint. Push and pull are the same round trip, because a client that has
changes almost always wants the other side's too, and splitting them doubles the
latency for no benefit.

Tokens are the API's own access tokens, signed **ES256** with an asymmetric key held
by the auth service. Verifiers check them against its public half by the token's
`kid`, so a key can be rotated without invalidating tokens still in flight.

The sync API holds only the public half. It can check a token and cannot forge one; a
compromised sync server cannot mint a session for another customer.

`sub` is the user id. Every row the request touches belongs to that user; a
`user_id` in a request body is ignored, never trusted.

## Request

```json
{
  "protocolVersion": 1,
  "deviceId": "018f3a1e-...",
  "timeZone": "Asia/Karachi",
  "cursor": 4711,
  "changes": [
    {
      "table": "segments",
      "op": "upsert",
      "row": {
        "id": "018f3a1e-8c2b-7d61-9f04-2a1b3c4d5e6f",
        "dayDate": "2026-08-03",
        "type": "work",
        "startedAt": 1785751200000,
        "endedAt": 1785754800000,
        "note": null,
        "createdAt": 1785751200123,
        "updatedAt": 1785754800456
      }
    },
    { "table": "days", "op": "delete", "row": { "id": "018f...", "updatedAt": 1785754900000 } }
  ]
}
```

| Field | Meaning |
|---|---|
| `protocolVersion` | Always `1`. A server that does not recognise the value refuses the request rather than guessing. |
| `deviceId` | Stable UUID per installation. Used for diagnostics and to let a client recognise its own echoed writes. |
| `timeZone` | Optional. The client's IANA zone, which decides when its days lock (see *Locked days*). Sent on every sync, because a zone recorded once at sign-in is wrong the day its owner travels. Absent or unknown, the server uses the sign-in zone, then UTC. |
| `cursor` | Highest `seq` this client has durably stored. `0` on first sync. |
| `changes` | May be empty — an empty push is the normal way to poll. |

Instants are UTC epoch milliseconds, matching `EpochMs` in DeyleeKit. Never an ISO
string: a string implies a timezone that a UTC instant does not have.

`createdAt` and `updatedAt` are the **client's** claims. The server stores them
unmodified because conflict resolution compares them; a server that stamped
`updatedAt` would make every synced row look freshly edited and hand every conflict
to the staler device.

`op: "delete"` carries only `id` and `updatedAt`. The server sets `deletedAt`; the
row itself is retained.

## Response

```json
{
  "protocolVersion": 1,
  "cursor": 4890,
  "serverTime": 1785754900000,
  "hasMore": false,
  "results": [
    { "id": "018f3a1e-...", "status": "applied" },
    { "id": "018f3b2f-...", "status": "rejected", "code": "overlap",
      "message": "Overlaps a segment from 10:00 to 11:00",
      "conflictsWith": ["018f3a1e-..."] }
  ],
  "changes": [ { "table": "segments", "op": "upsert", "row": { "...": "...", "seq": 4890 } } ]
}
```

**`results` is per-change, and a rejection is not fatal.** One bad row must not
block the rest of the batch — a client with a corrupt local row would otherwise be
unable to sync anything, ever. Each change is applied in its own savepoint.

**`changes` contains rows with `seq > cursor`**, ordered by `seq` ascending, capped
at 500 per response. When `hasMore` is true the client immediately calls again with
the new cursor. A first sync of several years of history is many round trips by
design; the alternative is one request that times out.

**`serverTime`** lets a client measure its own clock skew. A device more than a few
minutes out will produce segments that look wrong to every other device, and it
should say so rather than silently recording nonsense.

**The client advances its cursor only after the pulled rows are durably committed
locally.** A cursor advanced before the write is a cursor that skips rows after a
crash.

## Cursor ordering, and the hazard it hides

`seq` comes from one Postgres sequence shared by all syncable tables, assigned by
trigger. The obvious implementation has a silent data-loss bug:

> `nextval()` is handed out when a row is written, but transactions commit in a
> different order than they started. A pull can observe `seq = 100` and advance its
> cursor while a transaction holding `seq = 98` has not committed yet. That row is
> then never delivered — the client asks for `seq > 100` forever after.

The fix is to make writes for a single user strictly serial:

```sql
select pg_advisory_xact_lock(hashtextextended(<user_id>::text, 0));
```

taken at the start of every push transaction. Two pushes for the same user can no
longer interleave, so per-user `seq` order matches per-user commit order and
`seq > cursor` is complete. Different users still write concurrently, and a pull
filters by `user_id`, so cross-user interleaving is harmless.

Gaps in the numbers are expected and fine. Only the *ordering* carries meaning; the
cursor is never treated as a count.

## Conflict resolution

Segments belong to exactly one person and are effectively append-only, so genuine
conflicts are rare and last-write-wins is sufficient. Per row:

1. A **strictly** higher `updatedAt` wins.
2. An equal `updatedAt` is a no-op — the stored row stands. Note that a tie cannot
   be broken by `id`: both sides of the comparison are versions of the *same* row
   and therefore share one. "No-op on equal" is what makes a replayed push safe,
   which the idempotency rule below requires anyway.
3. A tombstone beats an update at the same `updatedAt`, so deletion uses `>=` where
   an update uses `>`. Deletion is the more conservative outcome: the row still
   exists and can be restored, whereas resurrecting time the user deleted shows
   them hours they thought were gone.

The winner is returned in `changes`, so a client that lost always learns the
resolved state in the same round trip.

CRDTs are deliberately not used. They earn their complexity when several people edit
one object; here each row has a single owner and the merge rule above is one line to
implement per platform.

## The open segment, across devices

At most one segment per user may be open, app-wide and device-wide. This is enforced
by `segments_never_overlap` in the database — an open segment is an unbounded range,
so a second one necessarily overlaps.

When a client pushes a start while another device holds an open segment, the server
rejects it with `code: "open-elsewhere"` and returns the open segment in
`conflictsWith`. The client then shows the user the choice rather than deciding for
them:

- **Take over** — close the other segment at its last known heartbeat, then retry.
- **Discard** — abandon the local start.

Silently closing the other device's segment would delete time the user was arguably
working, and silently refusing would leave a timer that visibly does nothing.

## Error codes

Transport-level failures use HTTP status; per-row failures use `code` in `results`
with HTTP 200, because the batch as a whole succeeded.

| HTTP | When |
|---|---|
| `400` | Malformed body, or unknown `protocolVersion` |
| `401` | Missing, expired, or unverifiable token |
| `409` | `cursor` is ahead of the server's max `seq` — the client is talking to a restored backup and must resync from `0` |
| `413` | More than 500 changes in one push |
| `429` | Rate limited; `Retry-After` is authoritative |
| `5xx` | Retry with exponential backoff and jitter |

| `code` | Meaning |
|---|---|
| `overlap` | Would overlap an existing live segment |
| `open-elsewhere` | Another device holds the open segment |
| `invalid-range` | `endedAt` is not after `startedAt` |
| `invalid-shape` | A field failed validation (bad DateKey, note too long, unknown `type`) |
| `stale` | A newer version of this row already exists; the winner is in `changes` |
| `locked` | The segment's day has ended by the server's clock; the server's copy is in `changes`, and the client must put it back over its own |

These mirror `MutationErrorCode` in `Sources/DeyleeKit/Models.swift` so the macOS app
can surface a server rejection through the path it already uses for local ones.

## Witnessed time — `POST /v1/beat`

A second endpoint, sharing the same bearer token. While a **work** segment is open,
the client posts a heartbeat every 30 seconds:

    POST /v1/beat
    Authorization: Bearer <access token>
    Content-Type: application/json

    { "deviceId": "<uuid>" }          // optional

    → 200  { "recorded": true }       // false if inside the server's dedup floor

The point is a property nothing else in the protocol has: **a beat can only be
recorded in the present.** The server stamps each one with its own clock and accepts
no timestamp from the client, so hours that were witnessed by a live client cannot be
manufactured after the fact — not by editing the local store, not by a replayed
request, not by a stolen token posting `/v1/sync`. Time therefore divides into two
honest categories, *witnessed* and merely *claimed*, and offline work is legitimately
the latter.

Rules:

- **The body carries nothing but an optional `deviceId`.** No app names, no titles,
  no state beyond the fact of running. Hours, never how — the same promise the sync
  payload keeps.
- **The server deduplicates below ~20 seconds.** A faster beat returns
  `recorded: false`, which is a success: the client uses it only to avoid logging
  noise. This bounds the table's growth and turns a flood into a no-op.
- **Silence is the offline state, not an error.** A beat that cannot be delivered
  means those minutes stay claimed. Nothing about a failed beat may reach the user.
- **Beats are compacted as they age.** Raw for 30 days, then one span per unbroken run
  of beats, and after 90 days one total per user per day — by UTC day, and without
  changing what the report counts. Nothing a client sends or receives changes.
- **The witness log is server-only.** It is never pulled, has no `code` in any
  `results`, and the API role holds no grant to its table; the sole writer is a
  `SECURITY DEFINER` function that reads the caller's identity from the transaction,
  not from the body.

Only `.running` beats. A paused day, a break, or an ended day goes silent within one
interval, so witnessed time reflects work and nothing else.

## Hour slips — `POST /v1/hour-slips` and `GET /slip/<token>`

A signed statement of one person's claimed and witnessed hours for a run of ended days,
which they hand to whoever needs proof — a client, an employer. Same bearer token:

    POST /v1/hour-slips
    { "from": "2026-09-01", "to": "2026-09-05", "timeZone": "Asia/Karachi" }

    → 200 {
        "url": "https://api.faizraza.me/slip/<token>",
        "issuedAt": 1790000000000,
        "name": "…", "email": "…",
        "from": "2026-09-01", "to": "2026-09-05", "timeZone": "Asia/Karachi",
        "claimedMs": 100800000, "witnessedMs": 99120000,
        "days": [ { "date": "2026-09-01", "claimedMs": …, "witnessedMs": …,
                    "witnessedApproximate": false }, … ]
      }

Rules:

- **Only ended days.** Each date must be past its lock by the server's clock (see *Locked
  days*), or ended by the person with no segment still open on it — so today can go on a
  slip once the day is ended. `400` otherwise, and for more than 30 days or an unknown zone.
  `503` when the server has no slip key.
- **Claimed** is the day's work segments as the server holds them — so a client syncs
  before asking. **Witnessed** is time the server heard a running timer, split by the
  person's own local days from `timeZone`. Days older than 90, whose beats survive only
  as a UTC-day total, carry `witnessedApproximate: true`.
- **Nothing is stored.** The token in `url` carries the signed totals; `GET /slip/<token>`
  checks the signature (a key used only for slips) and re-derives the figures from the
  record, showing the person's name, full email and hours to whoever opens it. That page
  is the point of a slip, and only the person recorded can create one.
- **A slip expires when its hours change.** The token also carries a fingerprint of the
  recorded time it covers: each segment's id, type, start, end and deletion, and each day's
  ended mark. If any of that changes after signing — a day reopened and ended again, time
  added, moved or deleted — the page says the slip has expired and shows no hours. Notes
  are not on a slip and do not expire it; nor does compacting witness beats.

## Idempotency

Every request must be safe to send twice. Networks drop responses, and a client that
cannot retry loses data.

Upserts key on `id`, so replaying one is a no-op or a same-value write. Deletes set
`deletedAt` only if it is currently null. Clients keep changes marked dirty until a
response confirms them, and clear the flag only on `status: "applied"`.

A push whose response never arrives is retried with the identical body. The server
must not treat that as a conflict with itself.

## Versioning

`protocolVersion` is an integer that only ever increases. A server supports the
current version and the one before it, giving clients a release cycle to catch up —
mandatory when the browser extension and the Android app update on schedules nobody
controls.

Additive fields do not bump the version; clients ignore fields they do not know.
Removing a field, changing a type, or changing the meaning of an existing value does
bump it.

## Not in v1

Recorded so nobody assumes otherwise:

- **Organisations, teams and roles.** Every row already carries `user_id`; org
  tenancy widens that check rather than reshaping rows.
- **Realtime push.** Clients poll — on foreground, on wake, and on an interval.
  WebSockets can arrive later without a protocol change.
- **Projects and billable rates.** The commercial feature set, deliberately after
  sync is proven.
- **Server-side day rollups.** Totals stay derived.

## Locked days

A day's recorded time is final two hours after its midnight, in the client's zone, by the
**server's** clock. From then on the server refuses — as `locked` — any change to a
segment's `startedAt`, `endedAt`, `type` or `dayDate`, and any delete, and moving a
segment onto a locked day. The client's own clock is never consulted, so a device whose
date was set back cannot reopen a day.

Still accepted on a locked day, because refusing them loses honest time:

- **A note edit.** Words about the time, not the time.
- **Closing or discarding an open segment.** The timer closes one when a machine slept
  across midnight; crash recovery discards one. An open segment holds no recorded hours.
- **A segment the server has never seen.** Work recorded offline and synced late. It is
  kept, and marked as a late claim, so it reads as claimed rather than witnessed. An
  *open* segment for a locked day is refused: an honest client closes and splits at
  midnight before it syncs.

A refusal carries the server's copy of the row in `changes`. Last-write-wins would keep
the client's edit — it is the newer one, and on a clock set back its `updatedAt` means
nothing — so the client must overwrite its row with that copy, whatever the timestamps
say, and treat it as clean. Clients should also refuse these edits locally, judged by
the server time of their last sync (`serverTime`), so the user is told where they type.

## Integrity, in one place

The server does not trust the client, because the client runs on a machine its owner
controls. Three mechanisms, all server-side, none of which reads as *how* anyone
worked:

- **Bounds** refuse the impossible at the door — a segment over sixteen hours, a
  timestamp in the future — as ordinary per-row rejections.
- **Marks** are ink, not walls. Editing or deleting hours that already synced, and
  hours first filed more than two days late or onto a locked day, each leave a row in
  an audit table the client protocol cannot name. Edits stay allowed while the day is
  open; they simply stop being invisible.
- **Locked days** (above) are the one wall: once a day has ended by the server's clock,
  its recorded times are final.
- **Witnessed time** (above) is the server's own record of a live client, which no
  after-the-fact request can fabricate.

What none of them stops is a person driving the genuine app in real time — one fake
hour costs one real hour of pretending. That residue is where every honest tracker
lands.

Screen capture does not change that reasoning, because it is not an integrity
mechanism here. It is off by default and only the recorded person can enable it, so
it can never be relied on to police them — which is precisely why the server-side
mechanisms above exist and are not optional. See `PRODUCT.md` §3.

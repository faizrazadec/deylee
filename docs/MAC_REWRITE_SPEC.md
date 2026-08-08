# Deylee — macOS Native Rewrite Specification

This document is the contract for rewriting Deylee (Electron + TypeScript + React +
SQLite) as a native Swift/SwiftUI macOS app with identical functionality and design.
It was synthesized from an exhaustive survey of the shipped codebase. Where
`docs/DESIGN.md` and the shipped code diverge, **this spec documents the shipped
code** (the running ground truth) and flags the divergence in §9 Open questions.
All user-visible strings quoted here are exact copy and must be reproduced verbatim.

---

## 1. Product overview and non-goals

Deylee is a **local-first** desktop time tracker that lives in the menu bar. One
timer, one day at a time: the user starts work, pauses for breaks, ends the day.
Time is stored as immutable segments in a local SQLite file; every displayed total
is derived by summing segments — nothing is ever a running counter.

**Local-first, not local-only.** Every write lands in SQLite before anything else
happens, and the UI reads only from there, so the app is fully usable with no
network at all. Sync is a background reconciliation on top of that — see
`SYNC_PROTOCOL.md`. A timer that stops working on a train would be worse than one
that never synced, which is why the local store is the source of truth for a write
until the server has acknowledged it.

Surfaces:

- **Menu-bar status item** — template clock glyph; live `H:MM` worked title while
  running/paused; left-click toggles the panel; right-click shows a context menu.
- **Panel** (320 × 436) — the primary popover UI: state, live timer, target
  progress, today's segments, prompts (crash recovery / idle / wake), footer nav.
- **Mini window** (180 × 56) — optional always-on-top floating readout (off by
  default on macOS).
- **History window** (900 × 640) — month calendar/list, week+month roll-ups,
  day detail, manual segment add/edit/delete, CSV/JSON export.
- **Settings window** (560 × 640) — all preferences, data folder, backup, updates.

Identity: app name **Deylee**, bundle id `me.faizraza.deylee` (Electron build),
category `public.app-category.productivity`, `LSUIElement: true` (accessory app —
no Dock tile except while History/Settings is open). Version 0.1.0 at time of
survey; version is owned by release tooling, never hand-edited.

**Non-goals (binding):**

- **No telemetry, ever.** Nothing about how the app is used leaves the machine.
- **Accounts and sync are optional, never required.** Signed out, the app behaves
  exactly as it always has: local SQLite, no network, no account. Signing in adds
  sync; it does not become a precondition for tracking time.
- The network requests the app may make are: a preference-gated update check
  against GitHub Releases (`https://github.com/faizrazadec/deylee-ios/releases`),
  and — only when signing in or signed in — `POST /v1/auth/google`,
  `/v1/auth/signup`, `/v1/auth/password`, `/v1/auth/refresh`,
  `/v1/auth/set-password` and `POST /v1/sync`. That is the complete list; keep it
  complete, because §5.5's Data copy is a promise made to somebody standing on the
  screen where they check. Nothing downloads without an explicit user action.
- **Only hours ever leave the machine.** Segments, days and their timestamps sync;
  nothing else does. No window titles, no document names, no application names, no
  screenshots, no keystroke or mouse activity, no productivity score. This is the
  load-bearing claim of the product (see `PRODUCT.md`) and no feature may weaken it.
- No stored totals or status columns anywhere — totals are always summed from
  segments at read time. This holds on the server too: nothing aggregated is ever
  transmitted or persisted.
- The UI never mutates optimistically. It waits for the engine's next snapshot,
  and sync never writes to the UI's view of the world directly.

**Superseded non-goals.** These were binding and no longer are; recorded so the
change is visible rather than silently rewritten:

- *"No accounts, no cloud, no sync"* — superseded. Deylee is being sold to
  companies, which need multi-device sync and a manager-facing view.
- *"No server component"* — superseded by `server/`, a Hummingbird API that
  imports DeyleeKit so the day-boundary, overlap and midnight-split rules are the
  same code on both sides rather than a port that drifts.
- *"Windows and Linux are not targets"* — superseded. macOS, iOS, web, Windows,
  Android and a browser extension are all planned. They are thin clients against
  `SYNC_PROTOCOL.md`; the invariants live on the server precisely so six
  implementations cannot disagree about them.
- *"No multiple projects/tags/clients. One timeline of `work`/`break` segments."* —
  **deferred, not abandoned.** It describes what ships today and it is still the
  right default: one timer, one day, nothing to configure before the first start.
  But a company cannot allocate cost or invoice against an unlabelled timeline, so
  an optional project (and later a billable rate) is a committed part of the
  commercial feature set — after sync is proven, per `SYNC_PROTOCOL.md`. Read this
  row as "not yet", never as "no": nothing here licenses a design that would make
  attributing a segment to a project impossible to add.

---

## 2. Data model

### 2.1 Database file and location

- Filename: **`deylee.sqlite`**, at `<userData>/deylee.sqlite`.
- Electron `userData` on macOS is **`~/Library/Application Support/deylee/`**
  (lowercase `deylee` — package.json has no `productName`, so `app.name` is the
  package name; verified against the packaged app and the live machine).
- **Absolute import path: `~/Library/Application Support/deylee/deylee.sqlite`**.
- The same folder holds `preferences.json` (electron-store, see §7) plus Chromium
  cruft (irrelevant).
- Journal mode is **WAL** (persisted in the file header), so `deylee.sqlite-wal`
  and `deylee.sqlite-shm` sidecars exist while the Electron app runs. **A naive
  byte-copy of only the `.sqlite` file can silently miss the newest commits.**
  Import must either open the file normally (replaying the WAL) or use the SQLite
  online backup API (`sqlite3_backup_init/step/finish`, or `VACUUM INTO`).

### 2.2 Connection pragmas (apply in this order)

1. `journal_mode = WAL` (first, property of the file; readers don't block the writer)
2. `foreign_keys = ON` (required for `ON DELETE CASCADE`; per-connection)
3. `busy_timeout = 5000`
4. `synchronous = NORMAL` (paired with WAL deliberately; power loss can cost the
   last commit, never the file)

Single write connection for the app's lifetime; all repository calls synchronous.

### 2.3 Schema v1 (verbatim; verified byte-identical in the live user DB)

`CURRENT_SCHEMA_VERSION = 1`. Migration 1 executes:

```sql
CREATE TABLE IF NOT EXISTS days (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  date           TEXT    NOT NULL UNIQUE,
  created_at     INTEGER NOT NULL,
  ended_at       INTEGER,
  target_minutes INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS segments (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  day_id     INTEGER NOT NULL REFERENCES days(id) ON DELETE CASCADE,
  type       TEXT    NOT NULL CHECK (type IN ('work','break')),
  started_at INTEGER NOT NULL,
  ended_at   INTEGER,
  note       TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_segments_day ON segments(day_id, started_at);
-- Partial index: the open-segment lookup runs on every snapshot; at most one row matches.
CREATE INDEX IF NOT EXISTS idx_segments_open ON segments(ended_at) WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS app_state (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

Bootstrapped **outside** the migration list (must exist to read the version):

```sql
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)
```

- `PRAGMA user_version` is **not** used (it is 0); the `schema_version` table is
  the sole version authority.
- `AUTOINCREMENT` means ids monotonically increase and are never reused.

Column semantics:

| Column | Semantics |
|---|---|
| all `*_at` | **UTC epoch milliseconds** (INTEGER). Never local time on disk. |
| `days.date` | local calendar date key `YYYY-MM-DD`; sorts lexicographically (range queries rely on string `>=`/`<=`). |
| `days.ended_at` | NULL until End Day; **cleared back to NULL** if the user starts again afterwards. |
| `days.target_minutes` | snapshot of the daily target at day creation, minutes, always `round()`ed. Re-stamped only for the in-progress day when the preference changes; past days keep their target. |
| `segments.type` | exactly `'work'` or `'break'` (CHECK). Read-side coercion: anything not `'break'` reads as `'work'`. |
| `segments.ended_at` | NULL = open. Invariant: **at most one open segment app-wide.** |
| `segments.note` | nullable free text; on midnight split every piece keeps the full original note. |

Invariants: every stored segment belongs to exactly one local day (enforced by
midnight splitting); no totals are stored anywhere.

### 2.4 app_state contents

Single key in use: **`heartbeat_at`** — value is `String(Date.now())` (decimal
string of UTC epoch ms). Written every 30 s while a segment is open, immediately
on start, and once more first thing during teardown. Read at startup for crash
recovery: trim, empty → null, non-finite → null.

### 2.5 Migration mechanism (must be preserved for file compatibility)

1. `CREATE TABLE IF NOT EXISTS schema_version …`.
2. Read `SELECT version FROM schema_version ORDER BY version DESC LIMIT 1`;
   no row → 0.
3. If stored version > supported → refuse **before any write** with a
   `SchemaTooNewError`. Startup shows a dialog — title:
   `This data was written by a newer Deylee`; body:
   `Your database is at schema version ${stored}, but this build — Deylee ${version} — only understands version ${supported}.`
   (blank line)
   `Nothing has been changed and nothing has been lost. Update Deylee to the latest`
   `release and your data will open again exactly as you left it.` — then quit.
   Any other migration error → dialog titled `Deylee could not start` with the
   error message, then quit.
4. Pending migrations run ascending in **one transaction**; after each, `DELETE
   FROM schema_version` then `INSERT` the new version. Statements are idempotent;
   forward-only; no down-migrations.

### 2.6 Repository queries (exact SQL; columns always explicit, never `SELECT *`)

```sql
-- dayByDate      [date]
SELECT id, date, created_at, ended_at, target_minutes FROM days WHERE date = ?
-- dayById        [id]
SELECT id, date, created_at, ended_at, target_minutes FROM days WHERE id = ?
-- insertDay      [date, now, minutes]
INSERT INTO days (date, created_at, ended_at, target_minutes) VALUES (?, ?, NULL, ?)
-- updateDayEnded [endedAt|NULL, id]
UPDATE days SET ended_at = ? WHERE id = ?
-- updateDayTarget [minutes, id]   (by id, deliberately: only the day in progress is passed)
UPDATE days SET target_minutes = ? WHERE id = ?
-- segmentsByDay  [dayId]
SELECT id, day_id, type, started_at, ended_at, note, created_at, updated_at
  FROM segments WHERE day_id = ? ORDER BY started_at ASC, id ASC
-- segmentById    [id]
SELECT id, day_id, type, started_at, ended_at, note, created_at, updated_at
  FROM segments WHERE id = ?
-- openSegment    (oldest first, so a hypothetical backlog drains oldest-first)
SELECT id, day_id, type, started_at, ended_at, note, created_at, updated_at
  FROM segments WHERE ended_at IS NULL ORDER BY started_at ASC, id ASC LIMIT 1
-- insertSegment  [dayId, type, startedAt, endedAt|NULL, note|NULL, now, now]
INSERT INTO segments (day_id, type, started_at, ended_at, note, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
-- updateSegment  [type, startedAt, endedAt|NULL, note|NULL, now, id]
UPDATE segments SET type = ?, started_at = ?, ended_at = ?, note = ?, updated_at = ? WHERE id = ?
-- deleteSegment  [id]
DELETE FROM segments WHERE id = ?
-- range          [from, to]  (one pass for a whole month)
SELECT d.id AS day_id, d.date AS day_date, d.created_at AS day_created_at,
       d.ended_at AS day_ended_at, d.target_minutes AS day_target_minutes,
       s.id AS segment_id, s.day_id AS segment_day_id, s.type AS segment_type,
       s.started_at AS segment_started_at, s.ended_at AS segment_ended_at,
       s.note AS segment_note, s.created_at AS segment_created_at,
       s.updated_at AS segment_updated_at
  FROM days d LEFT JOIN segments s ON s.day_id = d.id
 WHERE d.date >= ? AND d.date <= ?
 ORDER BY d.date ASC, s.started_at ASC, s.id ASC
-- appStateGet    [key]
SELECT value FROM app_state WHERE key = ?
-- appStateSet    [key, value]
INSERT INTO app_state (key, value) VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value
```

Repository behaviors that are part of the contract:

- `getOrCreateDay(date, targetMinutes, now)`: find-or-insert;
  `Math.round(targetMinutes)`; new day has `ended_at = NULL`, `created_at = now`.
- `setDayEnded(dayId, endedAt|null)`: `null` clears the End-Day flag; missing row
  throws `Day ${id} does not exist.`
- `updateSegmentFields(id, patch, now)`: merges patch over the current row;
  `type`/`startedAt` merge with null-coalescing, but `endedAt`/`note` merge on
  explicit-presence so **an explicit `null` reopens a segment / clears a note**;
  always writes every mutable column; stamps `updated_at = now`; missing row
  throws `Segment ${id} does not exist.`
- **`closeSegmentSplitting(id, endedAt, targetMinutes, now)`** — the only way a
  segment is closed. In a transaction: load the original (throw if missing);
  `splitAtMidnight`; the **first piece keeps the original row id** (only
  `ended_at` updated — callers hold that id); each later piece gets
  `getOrCreateDay(piece.date, targetMinutes, now)` (day created on demand with
  the current preference value) and is inserted with the **original note copied
  onto every piece**. Returns pieces in ascending, contiguous order.
- `transaction(fn)`: nesting is safe (inner transactions become SAVEPOINTs).
- `getRange` groups the join rows in a single pass; a day with no segments yields
  an empty segments array; totals computed per day at read time.

### 2.7 Data import story (Swift app reading the Electron database)

- The importer must open (or online-backup from)
  `~/Library/Application Support/deylee/deylee.sqlite`, honoring the WAL sidecars.
- Preserve the `schema_version` table protocol and implement the same
  refuse-if-newer behavior so the two implementations never corrupt each other's
  files if they ever share one.
- A sandboxed Swift app cannot read that path from inside its container: either
  ship non-sandboxed, request the file via NSOpenPanel on a first-run import
  flow, or use a temporary sandbox exception. (Adopt-vs-copy is an open question,
  §9.)
- `preferences.json` sits beside the DB; its keys/defaults are in §7. Whether it
  is imported is an open question.
- Backup feature (user-invoked; keep identical): NSSavePanel titled
  **`Back up Deylee data`**, default filename `deylee-backup-${YYYY-MM-DD}.sqlite`
  (local date), filter "SQLite database" / `.sqlite`, create-directory and
  overwrite-confirmation enabled. Cancel is a normal outcome (no message). Copy
  via the SQLite **online backup API from a second read-only connection** (never
  a file copy); always close the second connection (an open one pins the WAL).
  Failure fallback message: **`The backup could not be written.`**

---

## 3. Core domain rules

### 3.1 Conventions (hold everywhere)

- Every instant is UTC epoch **milliseconds** (`EpochMs`) — the only wire and
  disk format. Render in local time only at display.
- A "day" is a **local calendar day**, keyed `YYYY-MM-DD` (`DateKey`). Days may
  be 23 h or 25 h across DST; all boundary math uses local-calendar construction.
- Totals are never stored; always derived by summation.
- At most one open segment (`endedAt == null`) app-wide.
- Interval convention is **half-open `[startedAt, endedAt)`**: touching endpoints
  are NOT overlaps (a pause/resume boundary shares an instant by design).
- Constants: `MS_PER_SECOND = 1_000`, `MS_PER_MINUTE = 60_000`,
  `MS_PER_HOUR = 3_600_000`.

### 3.2 Core types

```
SegmentType = 'work' | 'break'
TimerState  = 'IDLE' | 'RUNNING' | 'PAUSED' | 'ENDED'

IDLE ──start──▶ RUNNING ──pause──▶ PAUSED ──resume──▶ RUNNING …
                   │                  │
                   └──── endDay ──────┴──▶ ENDED ──start──▶ RUNNING (same day reopens)

Segment    { id, dayId, type, startedAt, endedAt|null, note|null, createdAt, updatedAt }
Day        { id, date, createdAt, endedAt|null, targetMinutes }
DayTotals  { workedMs, breakMs, firstStartAt|null, lastEndAt|null, segmentCount, hasOpenSegment }   // derived, never persisted
DayDetail  { day, segments (startedAt ASC), totals }
TimerSnapshot { state, date, dayId|null, closedWorkedMs, closedBreakMs,
                openSegment|null, firstStartAt|null, lastEndAt|null, targetMinutes, asOf }
LiveTotals { workedMs, breakMs, targetProgress /*0..1+, unclamped*/, targetMs, remainingToTargetMs /*may go negative*/ }
MutationResult<T> = { ok:true, value:T } | { ok:false, code, message }
MutationErrorCode = 'overlap' | 'invalid-range' | 'not-found' | 'open-segment-conflict' | 'unknown'
```

### 3.3 DST-correct day-boundary algorithm (port exactly)

All from `src/shared/time.ts`; on macOS use `Foundation.Calendar` with
`TimeZone.current`, verified against the JS semantics:

- `dateKeyOf(ts)` — local calendar date of `ts` as `YYYY-MM-DD` (local getters).
- `isDateKey(s)` — regex `^\d{4}-\d{2}-\d{2}$`, month 1–12, day 1–31, then a
  **round-trip check**: construct local `Date(y, m-1, d)` and require
  year/month/day read back unchanged (rejects `2025-02-30`).
- `startOfDay(date)` — local `Date(y, m-1, d, 0,0,0,0)`. **DST edge:** in zones
  where spring-forward happens at midnight (e.g. America/Santiago) local midnight
  does not exist; the constructor resolves to 01:00 and that forward-resolved
  instant IS the correct start-of-day. Swift: `Calendar.startOfDay(for:)` matches.
- `endOfDay(date)` = `startOfDay(addDays(date, 1))` (exclusive bound).
- `nextMidnightAfter(ts)` = `endOfDay(dateKeyOf(ts))` — DST-correct because it
  goes through local-calendar construction.
- `addDays(date, days)` — construct at **noon** (`Date(y, m-1, d+days, 12)`) so a
  ±1 h DST shift cannot change the calendar date, then `dateKeyOf`.
- `daysBetween(from, to)` — both anchored at local noon, difference divided by
  24 h and **rounded**. Negative when `to` precedes `from`.
- `eachDay(from, to)` — inclusive list; empty when span < 0.
- `startOfWeek(date, weekStartsOn)` — `dow` from a noon-anchored Date;
  `delta = (dow − weekStartsOn + 7) % 7`; `addDays(date, −delta)`.
  `WeekStart = 0 (Sunday) | 1 (Monday)`. `endOfWeek` = start + 6.
- `startOfMonth(date)` = `YYYY-MM-01`; `endOfMonth` = day 0 of next month, noon
  anchor.

Formatting (exact output shapes; **all clock output is forced 24-hour**):

| Function | Output |
|---|---|
| `formatHM(ms)` | `H:MM` — total minutes = `max(0, floor(ms/60000))`; hours unpadded, NOT wrapped at 24 (`26:05` possible); negative → `0:00`. |
| `formatHMS(ms)` | `H:MM:SS` — seconds floor, same rules. |
| `formatCompact(ms)` | `0m` / `24m` / `2h` (m==0) / `1h 24m`. Minutes floor, clamp ≥ 0. |
| `formatClock(ts)` | local `HH:MM`, both zero-padded, 24-hour (not locale-driven). |
| `formatClockSeconds(ts)` | local `HH:MM:SS` (CSV export only). |
| `formatDateLong(date)` | host-locale `toLocaleDateString` with `{weekday:'short', day:'numeric', month:'short', year:'numeric'}` → e.g. `Mon 4 Aug 2025`; noon-anchored. |
| `fromTimeInputValue(date, time)` | parse `HH:MM[:SS]`: each part must be 1–2 plain digits (rejects `'09:'`, `'0x10'`, `'1e1'`, `' 9'`, `'+9'`, empty); ranges 0–23/0–59/0–59; local instant or null. |

### 3.4 Duration/totals derivation

- `spanDuration(span, now)` = `max(0, (endedAt ?? now) − startedAt)` — never
  negative; open spans measured to `now`.
- `spanDurationWithinDay(span, date, now)` — clip to
  `[startOfDay(date), endOfDay(date))`; matters only for the open segment (stored
  segments are pre-split at midnight).
- `dayTotals(segments, date, now)`: sum clipped durations per type into
  workedMs/breakMs; `firstStartAt` = minimum **raw** (unclipped) `startedAt`;
  `lastEndAt` = maximum closed `endedAt` but **null while any segment is open**;
  `segmentCount` = all segments; `hasOpenSegment`.
- `liveTotals(snapshot, now)` (the 1 Hz render contract): start from
  `closedWorkedMs`/`closedBreakMs`; if an open segment exists, add
  `max(0, now − max(open.startedAt, startOfDayAt(now)))` — clamped to the
  **current** local midnight, not the snapshot's date — to worked or break by
  type. `targetMs = max(0, targetMinutes) × 60000`;
  `targetProgress = targetMs > 0 ? workedMs/targetMs : 0` (unclamped);
  `remainingToTargetMs = targetMs − workedMs`. Renderers recompute this every
  second from timestamps; **never increment a counter** — this is what makes the
  numbers survive sleep, clock changes and midnight.
- `hoursToMinutes(h) = round(h × 60)`.

### 3.5 Midnight splitting

- `crossesMidnight(span)` — true only when closed, `endedAt > startedAt`, and the
  two endpoints have different date keys.
- `splitAtMidnight(span)`:
  1. Open span → single open piece (never split until closed).
  2. `endedAt <= startedAt` → returned unchanged as one piece (caller's
     validation decides rejection).
  3. Else walk `cursor` from `startedAt`; each piece ends at
     `min(nextMidnightAfter(cursor), endedAt)`. Pieces are contiguous
     (`piece[n].endedAt == piece[n+1].startedAt`), ascending; a span ending
     exactly at midnight produces **no empty next piece** (strict `<` loop).
- `splitOpenSpanAt(span, now)` (rollover of a running segment): null if closed or
  `now < nextMidnightAfter(startedAt)`; else `{ closed: splitAtMidnight(span
  closed at start-of-current-day), reopened: open piece starting at
  start-of-current-day }`. Note: for a multi-day open span, the reopened piece
  deliberately absorbs start-of-today→now as live open time.

### 3.6 Overlap validation

- Open end treated as `+∞`. `intervalsOverlap(a,b)` =
  `a.startedAt < ub(b) && b.startedAt < ub(a)` (half-open; touching is fine).
- `validateSegment(candidate, existing, ignoreId?)` — checks in order, exact
  messages:
  1. non-finite start → `invalid-range`, `Start time is not a valid instant.`
  2. non-finite end → `invalid-range`, `End time is not a valid instant.`
  3. `endedAt < startedAt` → `invalid-range`, `End time is before the start time.`
  4. `endedAt == startedAt` → `invalid-range`, `Start and end time are the same.`
  5. overlap → `overlap`,
     `Overlaps the ${type} segment from ${formatClock(start)} to ${end}.` where
     end is `now` for an open clash, else `formatClock(endedAt)`.
  `ignoreId` excludes the row being edited from its own comparison.

### 3.7 Range roll-ups (History)

- `summariseRange(range, days)` → `{ range, days, totalWorkedMs, totalBreakMs,
  activeDayCount, averageWorkedMsPerActiveDay, targetMetCount }`. Active day =
  `workedMs > 0`. `targetMetCount` counted only on active days and only when
  `targetMinutes × 60000 > 0 && workedMs >= targetMs`. Average divides by
  **active** days (weekends don't drag it down); 0 when none.
- `densifyRange(range, days)` → map with an entry for every calendar day in the
  range, null where no data.
- `weekRange` / `monthRange` / `subRange` as per §3.3 helpers.

---

## 4. Timer engine

The engine is the **only writer** of timer segments. **No timer state is
persisted** — state is derived on every read from (the one open segment, today's
day row); `kill -9` cannot corrupt it. Every transition that cannot legally
happen from the current state is a **silent no-op returning the current
snapshot** (never throws).

### 4.1 Snapshot derivation (`getSnapshot(now)`)

1. `date = dateKeyOf(now)`; `day = findDay(date)`; `open = findOpenSegment()`
   (**app-wide** — before the rollover tick, yesterday's open segment still
   drives state); `segments = day's segments or []`.
2. State: open work → `RUNNING`; open break → `PAUSED`; else day exists with
   `endedAt != null` → `ENDED`; else `IDLE`.
3. `closedWorkedMs`/`closedBreakMs` = sum of **closed** segments clipped to the
   day; the open segment ships untouched so renderers recompute live values.
4. `targetMinutes` = day's stamped target if the day row exists, else
   `round(dailyTargetHours × 60)` from the live preference.

### 4.2 Transitions (each mutating one runs in a transaction, then emits)

- `start()` — IDLE/ENDED → RUNNING. No-op if anything is open. Opens a work
  segment at `now`; `getOrCreateDay`; if the day was ended, clear `ended_at`
  (restart un-finalises the same day).
- `pause()` / `resume()` — switch the open segment work↔break:
  `at = max(now, open.startedAt)` (backwards-clock guard); close via
  `closeSegmentSplitting(open.id, at, …)` then open the other type at exactly
  `at` (touching endpoints, not overlap).
- `endDay()` — RUNNING/PAUSED → ENDED. `at = max(now, open.startedAt)`; close
  splitting; `day = getOrCreateDay(dateKeyOf(at), …)` (the day `at` falls in);
  `setDayEnded(day.id, at)`. Note: on a backwards clock edge endDay closes
  zero-length rather than deleting (unlike recovery-close, which deletes — see
  §9).
- Midnight rollover (`rollOverMidnight`): if the open segment has crossed local
  midnight, close it at the boundary (repository keeps the original row id) and
  reopen the **same type** at the boundary. Driven by a **1 s interval** (a timer
  aimed at midnight would sleep through it); the loop also broadcasts a snapshot
  when the date or the open-segment id changed even when no split occurred (the
  IDLE date flip at midnight).
- `syncTodayTarget()` — re-stamps only the current day's target from the
  preference; returns the changed dates; unchanged value or no day row → no-op.
  Deliberately silent (the caller broadcasts history-invalidated + emits).

### 4.3 Crash recovery (heartbeat)

- `HeartbeatService`: writes `app_state.heartbeat_at = String(Date.now())` every
  **30 000 ms** while a segment is open (work or break), immediately on start,
  and once more first thing during teardown. Write failures are logged, never
  fatal. Started/stopped from each snapshot (`openSegment != null`).
- Startup, **before the timer service exists**: if an open segment survived,
  build `PendingRecovery { segment, date: dateKeyOf(startedAt), lastHeartbeatAt,
  recoverableMs, gapMs }` where the close instant is
  `lastHeartbeatAt == null ? startedAt : clamp(lastHeartbeatAt, [startedAt, now])`;
  `recoverableMs = max(0, closeAt − startedAt)`; `gapMs = max(0, now − closeAt)`.
- `RECOVERY_GAP_FLOOR_MS = 1_000`: prompt only when `recoverableMs >= 1000 ||
  gapMs >= 1000`; otherwise silently discard (delete) the segment.
- Choices (`RecoveryChoice`): `'resume'` (leave open, keep counting),
  `'close-at-heartbeat'` (close at the clamped heartbeat instant; if that would
  be `<= startedAt`, **degrade to discard** — no phantom zero-length rows),
  `'discard'` (delete).
- A clean quit with a running timer leaves the segment open on disk; next launch
  shows recovery with `recoverableMs` ≈ time up to quit (final heartbeat) and
  `gapMs` ≈ downtime.

### 4.4 Idle detection

- `IdleMonitor`: polls every **15 000 ms**, only while state is RUNNING and pref
  `idleDetectionEnabled` is on. Threshold = `idleThresholdMinutes × 60_000`
  (pref, default 10, clamp 1–240). macOS idle source:
  `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …) × 1000`
  (null-read branch kept for safety; never null on macOS).
- **Edge-triggered**: one report per idle stretch (`reported` latch); re-armed
  only when idle drops back below threshold (user returned); leaving RUNNING
  clears the latch. Re-check running+pref after the async read. Re-entrancy
  guard against a slow read overlapping the next tick.
- On trigger: `onIdleDetected(Date.now() − idleMs, idleMs)` (start derived by
  subtraction). Main builds `IdlePrompt { id: UUID, segmentId, idleStartedAt,
  idleMs }` **only if the open segment exists and is `'work'`**, opens the panel,
  and posts a notification — title `You were away`, body
  `Deylee kept counting for ${formatCompact(idleMs)}. Keep it or drop it?`
- Resolution (`IdleChoice = 'keep' | 'discard'`): `keep` → untouched (idle time
  stays work). `discard` → trim: `endedAt = clamp(idleStartedAt, [startedAt,
  now])`; if that would empty the segment, **keep instead** (trimming to nothing
  is unrepresentable — user can delete manually); else close at `endedAt` and
  reopen **the same type** at `now` — the idle stretch becomes simply absent
  from the record (not a break). Stale prompt id → no-op; segment gone or
  already closed → no-op.

### 4.5 Sleep/lock handling

- `PowerMonitorService` constants: watchdog tick **10 000 ms**
  (`SLEEP_WATCHDOG_INTERVAL_MS`), drift threshold **60 000 ms**
  (`SLEEP_DRIFT_THRESHOLD_MS`).
- Events: sleep (`NSWorkspace.willSleepNotification`) and lock
  (`com.apple.screenIsLocked` distributed notification) → `markAway(reason)`;
  wake (`didWakeNotification`) and unlock (`com.apple.screenIsUnlocked`) →
  `markBack()`. `WakeReason = 'suspend' | 'lock-screen'`.
- Preference gates checked **at away time**: `'suspend'` → `autoPauseOnSleep`
  (default true); `'lock-screen'` → `autoPauseOnLock` (default false).
- **Exactly one gap open at a time**: the first away event opens it (keeping the
  earliest instant and ITS reason); later away events fold in (ignored); the
  first return event closes it. A return with no open gap is ignored.
- **Wall-clock watchdog** (keep for parity; catches missed events and clock
  jumps): every 10 s compare `now` against `lastTickAt + 10_000`; bail if drift
  < 60 s, if a gap is open (the real event is more accurate), if
  `lastGapClosedAt >= previousTickAt` (a real pair already reported this
  absence), or if `autoPauseOnSleep` is off. Otherwise report the whole absence
  `[previousTickAt, now]` as away+back with reason `'suspend'`. Uses the wall
  clock deliberately (not monotonic). `lastGapClosedAt` is nullable ("never" ≠ 0).
- `handleAway(at)`: if no open segment or the open one is a **break** →
  `autoPausedByPower = false` (a break already accounts for the gap). Else
  `suspendAt(at)`: close the open work segment at `clamp(at, [startedAt, now])`;
  if that would be `<= startedAt`, leave it running (no empty rows). Then
  `autoPausedByPower = (openSegment == null)` — whether the close really
  happened is the only honest signal.
- `handleBack(awayAt, backAt, reason)`: only if `autoPausedByPower`; build
  `WakePrompt { id: UUID, reason, gapStartedAt: awayAt, gapEndedAt: backAt,
  gapMs: max(0, backAt − awayAt) }`; open panel + notification — title
  `Welcome back`, body `${cause} for ${formatCompact(gapMs)}. Count it as a break?`
  where cause = `Your screen was locked` (lock) or `This machine was asleep`
  (suspend).
- Resolution (`WakeChoice = 'resume' | 'count-as-break'`): `planWake` —
  `'resume'` or empty gap → open work at `gapEndedAt` (gap absent from record);
  `'count-as-break'` → insert a closed break `[gapStartedAt, gapEndedAt]`
  (midnight-split as needed) then open work at `gapEndedAt`. Either way work
  starts again. `applyWake` no-ops if **any** segment is open (a second open
  segment would corrupt the invariant).
- Edge: sleep while a break is open → nothing closes; on wake the open segment
  stands down the prompt; the break simply spans the sleep.

### 4.6 Reminder

- `ReminderService`: **60 000 ms tick** (not a long timeout — survives sleep and
  clock changes). Fires when: `reminderEnabled`, state is RUNNING, not already
  fired today (`lastFiredOn` DateKey, **in-memory only** — survives service
  stop/start but not relaunch), and local minutes-of-day ≥
  `reminderHour×60 + reminderMinute`. `lastFiredOn` is set **before** the
  callback (a throwing listener cannot re-fire loop). Moving the time earlier
  after today's fire does not re-fire.
- Fires a Notice `{ level:'info', title: 'Still tracking', body: 'Your timer is
  still running. End the day when you are done.' }` to the panel plus a system
  notification with the same copy.

### 4.7 Snapshot fan-out and event discipline

- Snapshot emissions come from: every transition, plan applications
  (recovery/idle/wake), midnight rollover splits, startup seed, every history
  mutation, and a daily-target change. There is **no periodic snapshot push**;
  renderers tick locally at 1 Hz using `liveTotals`. (A stale docstring claims a
  30 s heartbeat push — the heartbeat only writes a DB row; see §9.)
- Every data mutation pairs a **history-invalidated** broadcast (specific
  affected dates; empty array = "everything changed") with a fresh snapshot.
  Timer transitions invalidate `[snapshot.date]`.
- Prompts are correlated by UUID; resolving an unknown/stale id is a no-op
  returning the current snapshot. Recovery has no id (at most one, held singly).
- Prompt delivery always **opens the panel**; notifications' click action opens
  the panel too (a dismissed notification must never be the only way to answer).
  Only the recovery prompt is also pull-able on panel mount (catch-up read);
  idle/wake prompts sent to a dead window are lost by design.
- All service callbacks are fail-safe: listener exceptions caught and logged;
  heartbeat write never throws outward; rollover tick catches and logs.
- A `quitting` flag stops all broadcasts and periodic work once quit is
  requested.

### 4.8 Lifecycle ordering

Startup: configure accessory-app policy → open DB → migrate (refuse-newer per
§2.5) → **detect recovery before the timer service exists** → construct services
→ sync mini window from pref → reconcile launch-at-login (OS wins, §7) → start
idle/power/reminder/update services → tray init → apply startup recovery →
`emit()` seed → start the 1 s midnight-rollover loop.

Teardown (`before-quit`): set quitting → clear rollover interval → unsubscribe →
**write final heartbeat first** → stop heartbeat/idle/power/reminder → destroy
tray → flush pending mini-position write → destroy windows → close DB last.

Single-instance: second launch focuses the panel of the first. `window-all-closed`
never quits — quit only via tray menu Quit or the panel/system quit path.

### 4.9 Timing constants (complete)

| Constant | Value | Purpose |
|---|---|---|
| Heartbeat interval | 30 000 ms | crash-recovery stamp while a segment is open |
| Idle poll | 15 000 ms | idle detection cadence |
| Sleep watchdog | 10 000 ms | wall-clock jump detector cadence |
| Sleep drift threshold | 60 000 ms | min jump past expected tick to count as sleep |
| Reminder tick | 60 000 ms | reminder check |
| Midnight rollover | 1 000 ms | split check every second |
| Recovery prompt floor | 1 000 ms | min recoverable-or-gap worth prompting |
| Renderer live tick | 1 000 ms | recompute `liveTotals` |
| Tray refresh (macOS) | 1 000 ms | live title re-apply |
| Mini move debounce (main) | 300 ms | position persistence |
| Mini move settle (renderer) | 200 ms | redundant position report |
| "Saved" flash (Settings) | 1 800 ms | confirmation line |
| Update: first check delay | 10 000 ms | after launch (when auto-check applies) |
| Update: check interval | 6 h | chained timeout, pref re-read each boundary |

---

## 5. UI spec per surface

### 5.1 Status item (menu bar)

- `NSStatusItem` with variable length. **One template image for every state**: a
  clock glyph (ring outer radius 0.42·s, ring thickness 0.1·s, minute-hand
  capsule straight up length 0.225·s, hour-hand capsule right length 0.17·s,
  hand half-width 0.042·s; pure black + alpha), sized **16 × 16 points** with a
  32 px @2x representation, `isTemplate = true` (AppKit recolours for
  light/dark/highlight). Set the image **once** (the Electron build re-reads it
  every tick only as an implementation artifact).
- **Title** (text beside the icon): shown only while RUNNING or PAUSED —
  `formatHM(workedMs)` (worked time only, never break). IDLE and ENDED show the
  bare icon (empty title; collapse the icon-text gap — `imagePosition` imageOnly
  when empty, imageLeft otherwise). Paused shows the *frozen* total rather than
  hiding it.
- **Tooltip** (always), with `totals = "${formatHM(workedMs)} worked · ${formatHM(breakMs)} break"`
  (` · ` U+00B7, `—` em dash):
  - RUNNING → `Deylee — ${totals}`
  - PAUSED → `Deylee — paused · ${totals}`
  - ENDED → `Deylee — day ended · ${totals}`
  - IDLE, workedMs > 0 → `Deylee — stopped · ${totals}`; IDLE, 0 → `Deylee — not tracking`
- Refresh: title/tooltip re-applied every **1 s** and immediately on every timer
  snapshot; totals via `liveTotals(snapshot, now)`.
- **Left click** → toggle the panel anchored to the item's bounds. **Right click
  or control-click** → context menu. Reference NSStatusItem behavior (from the
  shipped native addon): `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`;
  the menu is held **detached** and temporarily attached + `performClick`ed for
  a secondary click, then detached on the next run-loop turn (a permanently
  attached menu would open on left click too); menu `autoenablesItems = false`.
- **Highlight**: `button.isHighlighted` held for exactly as long as the panel is
  visible (driven by the panel's real show/hide/close events; in-process Swift
  can set it synchronously with the toggle).
- Context menu (exact structure/labels; rebuilt **only when TimerState
  changes** — rebuilding more often would close it under the cursor):
  1. Primary — `Pause` (RUNNING) / `Resume` (PAUSED) / `Start` (IDLE, ENDED);
     always enabled. Dispatch resolves the action from the **live** state at
     click time, not the state the menu was built for.
  2. `End Day` — enabled only when RUNNING or PAUSED.
  3. separator
  4. `Open Deylee` (opens the panel), 5. `History`, 6. `Settings`
  7. separator
  8. `Quit`
- `getBounds` returns null before the menu bar lays the item out (placeholder
  rect) → caller centers the panel instead of anchoring.

### 5.2 Panel (popover)

**Window**: 320 × 436, fixed, frameless, non-activating panel (Electron
`type:'panel'` = NSPanel — floats over fullscreen apps, never activates the app
over the frontmost one). Hides on blur (loses key). Closing **hides** rather
than destroys (instant reopen). Positioned 8 px (`PANEL_TRAY_GAP`) below the
status item, horizontally centered on it, clamped into the display work area
(opens upward if it would not fit below — moot under a top menu bar); null/zero
tray bounds → centered on the primary display's work area. Note: the fixed 436
height is what ships; DESIGN.md's content-driven 372–436 is an open question.

**Root**: 10 px corner radius, 1 px `border` stroke, `surface` background.
Header row is the drag region (irrelevant in a popover).

**Layout, top to bottom** (16 px side padding; 12 px main column gap):

1. **Header** (px 16, pt 12, pb 8, space-between):
   - Left: 8 px status dot + label, 11 px medium `fg-muted`, 6 px gap:
     IDLE → `Idle` / dot `fg-faint`; RUNNING → `Running` / dot `work` (green);
     PAUSED → `Paused` / dot `break` (amber); ENDED → `Day ended` / dot
     `accent` (neutral). Defaults to Idle before the first snapshot.
   - Right: `formatDateLong(snapshot.date)`, 11 px `fg-faint`, truncates.
2. **Hero** (centered): worked time `formatHMS(live.workedMs)` at **52 px,
   weight 300, line-height 1, letter-spacing −0.02 em, tabular numerals**; the
   final `:SS` at 0.5 em (26 px), normal tracking, color `fg-dim`. Sub-line
   (mt 8, 12 px `fg-muted`): `Break` (in `fg-faint`) + `formatCompact(breakMs)`
   (tabular) + when `firstStartAt != null`: ` · since ` (fg-faint) +
   `formatClock(firstStartAt)` (tabular).
3. **Target block** (vertical gap 6):
   - ProgressBar only when `targetMs > 0`: 6 px tall full-width rounded track in
     `sunken`; fill width = clamp(progress, 0, 1); fill color `accent`, switching
     to `work` green when unclamped progress ≥ 1; width+color transition 500 ms
     ease-out.
   - Label row, 11 px tabular `fg-faint`, space-between. Left: target set →
     `{formatCompact(workedMs)} of {formatCompact(targetMs)}`; no target →
     `{formatCompact(workedMs)} worked today`. Right (target set only):
     remaining > 0 → `{formatCompact(remaining)} left`, else `Target met`.
4. **Actions row** (gap 8): the state ActionButton (fills width) + `End day`
   secondary lg button **only when RUNNING or PAUSED**.
   - ActionButton mapping: RUNNING → `Pause`, secondary variant, pause icon;
     PAUSED → `Resume`, primary, play icon; ENDED → `Start again`, primary,
     play; IDLE → `Start`, primary, play. Size lg (44 px tall, 15 px text),
     14 px icon. Disabled until the first snapshot. All actions fire-and-forget;
     the UI never mutates locally — it waits for the snapshot push.
5. **Today section** (fills remaining height): heading `Today` — 10 px medium
   uppercase, wide tracking, `fg-faint`. Below, the segment list (scrolls,
   auto-pinned to bottom when the count changes so "now" is visible):
   - Data: today's `DayDetail`; re-fetched whenever a revision key changes
     (history invalidation, state change, open-segment id, closed totals).
     Failed reads are silent (no error UI at 320 px); loading shows nothing (no
     spinner — local reads land within a frame).
   - Empty day: dashed-border card — title `Nothing tracked yet`, description
     `Press Start to open the day.`
   - SegmentRow (read-only in the panel): rounded-lg bordered card
     (`accent/40` border when the segment is open, else `border`), hover fill;
     contents: type chip (`Work` in work colors / `Break` in break colors,
     11 px medium, 4–6 px radius, soft fill + 25 % border), time range 14 px
     tabular `fg-muted` — start `–` end, where an open end renders the literal
     word **`now`** in medium `accent`; optional note truncated 12 px
     `fg-faint` with full-text tooltip; right-aligned duration
     `formatCompact(spanDuration(segment, now))` 14 px medium tabular (open row
     climbs every second).
6. **Footer** (border-top, space-between, small ghost buttons):
   - Left: `History` → opens the History window.
   - Right: `Restart to update` — only when update status is `downloaded`;
     tooltip `Version {v} is ready`; installs immediately. This is deliberately
     the panel's only update UI. Then `Settings`.
   - (A `Quit` footer button exists only in the Linux no-tray fallback — NOT
     APPLICABLE; on macOS Quit lives in the status-item menu.)

**Notices** (between header and hero when present): non-modal banners,
`role=status` equivalent; info tone = `accent/30` border on `accent-soft`;
warning = `break/30` on `break-soft`; title medium, body `fg-muted`; dismiss X
button (`Dismiss: {title}` accessibility label). Producer on macOS: the
reminder notice (§4.6).

**End-day confirmation modal**: title `End the day?`; body: `This closes
whatever is running and finalises {formatCompact(workedMs)} of work. You can
still start again afterwards — the day simply reopens.` (worked value medium
tabular `fg`). Footer: ghost `Cancel` + danger `End day`. Dismissible (Escape /
backdrop). A queued prompt suppresses it and force-clears the pending confirm.

**Prompt queue**: recovery/idle/wake prompts are FIFO-queued (dedup keys
`recovery:{segmentId}` / `idle:{promptId}` / `wake:{promptId}`); only the head
renders; the queue advances on resolution **even if the call failed**; buttons
disable while resolving. These three modals are **non-dismissible** (no Escape,
no backdrop) — the user must choose. On panel mount, pull any pending recovery
once (broadcast raced during load).

- **RecoveryPrompt** — title `Unfinished session`. Body: `Deylee closed while a
  {work|break} segment was still running. It started at
  {formatClock(startedAt)} on {formatDateLong(date)}.` Stats card (2-column,
  sunken bg): `Recoverable` → `formatCompact(recoverableMs)`; `Unaccounted` →
  `formatCompact(gapMs)`. Three stacked full-width buttons each with an 11 px
  `fg-faint` hint:
  1. primary `Keep {formatCompact(recoverableMs)}` → close-at-heartbeat; hint
     `Ends the segment at the last heartbeat and drops the unaccounted time.`
  2. secondary `Resume it` → resume; hint `Leaves the segment open and keeps
     counting from when it started.`
  3. ghost `Discard` → discard; hint `Deletes the segment; none of that time is
     counted.`
- **IdlePrompt** — title `Away from your desk?`. Body: `You were idle for
  {formatCompact(idleMs)}, from {formatClock(idleStartedAt)} to
  {formatClock(idleStartedAt + idleMs)}.` Hint: `Keep counts that time as work.
  Discard ends the segment at {formatClock(idleStartedAt)} and opens a fresh one
  now, so the idle stretch is simply absent from the day.` Footer: ghost
  `Discard`, primary `Keep`. (Two choices only — DESIGN.md's third
  `convert-to-break` choice was never implemented.)
- **WakePrompt** — title `Welcome back`. Body: `{This computer was asleep|The
  screen was locked} for {formatCompact(gapMs)}, from
  {formatClock(gapStartedAt)} to {formatClock(gapEndedAt)}. Timing stopped the
  moment it happened.` Hint: `Resume work leaves the gap off the record. Count
  as break stores it as a break segment. Either way, work starts again now.`
  Footer: secondary `Count as break`, primary `Resume work`.

**Modal chrome** (shared): backdrop black/45 % + 2 px blur, centered; card
max-width 384, 10 px radius, `raised` bg, panel shadow; header border-b, title
14 px semibold; body 14 px relaxed `fg-muted`; footer right-aligned on `sunken`
with top border. Backdrop dismissal (where allowed) triggers on **mousedown that
starts on the backdrop** (a drag ending outside must not dismiss).

### 5.3 Mini window

**Window**: exactly **180 × 56**, borderless, transparent, not resizable,
always-on-top at **floating** level, visible on **all Spaces and over fullscreen
apps** (`[.canJoinAllSpaces, .fullScreenAuxiliary]`), shown **without ever
taking focus** (`orderFrontRegardless`, never make-key). No Dock/taskbar
presence. Existence bound entirely to the `showMiniWindow` preference (macOS
default **false** — the menu-bar title already shows the total); toggling the
pref creates/destroys it live. No close button on the window itself.

**Position memory**: per-display map `miniWindowPositions:
Record<displayId, {x, y}>` (merged per display, never replaced). On create:
candidates are primary display first, then other attached displays (an unplugged
monitor's spot never wins); first candidate with finite stored x/y wins, rounded
and clamped into that display's work area; default = primary work area
**top-right with a 24 px inset**. Persist on move, debounced **300 ms**, flushed
synchronously before destroy/quit. (Coordinates in the Electron file are
top-left-origin; convert to AppKit.)

**Card** (fills the window): corner radius 12 px (`rounded-xl`; the 13 px
`--radius-mini` token is defined but unused — see §9), 1 px `border`,
background `raised` at **80 % opacity** with **24 px backdrop blur** (blurs the
desktop behind), horizontal padding 12 px, items centered, gap 10 px. Everything
outside the rounded card is fully transparent. Row contents, left to right:

1. **State dot** — 8 px circle; same color/label map as the panel header (Idle
   `fg-faint`, Running `work`, Paused `break`, Day ended `accent`); accessible
   label = the state label.
2. **Worked total** — `formatHM(live.workedMs)` (**H:MM, no seconds**), 22 px,
   weight 400, line-height 1, tabular, tight tracking; truncates rather than
   pushing the button out. Ticks at 1 Hz via `liveTotals`.
3. **Action button** — 32 px circle, icon-only ActionButton (same state map and
   icons as the panel; `Start again` when ENDED); accessibility label + tooltip
   carry the label; disabled before the first snapshot.

**Interactions**: drag anywhere on the card moves the window
(`isMovableByWindowBackground`); the button area opts out. **Double-click
anywhere except the button opens the panel** (the button stops double-click
propagation so a fast pause/resume tap doesn't also open it). Whole-card tooltip
(exact template):
`{Label} · {formatCompact(workedMs)} worked · {formatCompact(breakMs)} break — double-click to open Deylee`.
No context menu, no edge snapping, no keyboard shortcuts.

### 5.4 History window

**Window**: 900 × 640, min 760 × 520, resizable, standard title bar, appears in
the Dock (activation policy flips to `.regular` while History or Settings is
open, back to `.accessory` when the last closes).

**Model**: one range in play — the **visible calendar month** (anchor =
`startOfMonth`); two presentations of it (Calendar / List); plus an independent
**week roll-up fetch** for the week containing the selected day (deliberately
not filtered from the month — a week straddling the boundary would
under-report); plus a **day detail column** for the selected day. Initial state:
anchor = current month, selected = today, view = calendar. A 60 s ticker keeps
"today" honest; the day panel ticks at 1 s. Data is never patched in place — any
mutation or invalidation bumps a revision and refetches both ranges.

**Header** (row, border-b, raised bg): `Previous month` / `Next month` chevron
buttons; month title 17 px medium, host-locale `{month:'long', year:'numeric'}`
(e.g. `July 2026`); ghost `Today` button; right-aligned segmented control
(`Calendar` | `List`) and `Export CSV` / `Export JSON` buttons (both disabled
while an export is in flight). Navigation: prev = month of (first − 1 day); next
= month of (last + 1 day); changing month clears the status banner and moves the
selection to today if today is inside the new month, else the month's first day
(selection always stays inside the visible month).

**Status banner** (below header, only when set by export outcomes): ok tone
(sunken/muted) or error tone (danger); text truncates with tooltip; ghost
`Dismiss` button.

**SummaryBar** — 5 stats (uppercase 10 px labels, 15 px medium tabular values,
optional 11 px hints; `—` placeholder while loading):
1. `Month` — `formatCompact(totalWorkedMs)`; hint `{formatCompact(totalBreakMs)} break`.
2. `Week` — `formatCompact(week.totalWorkedMs)`; hint `{d Mon} – {d Mon}`
   (both ends locale `{day:'numeric', month:'short'}`, separator space–en
   dash–space, e.g. `20 Jul – 26 Jul`).
3. `Average day` — `formatCompact(averageWorkedMsPerActiveDay)`; hint
   `across days with work` (always shown).
4. `Days logged` — `activeDayCount`.
5. `Target met` — `targetMetCount`; hint `of {activeDayCount} logged`.

**Calendar view**: locale short weekday header row rotated to `weekStartsOn`
(weekend columns Sun/Sat dimmer); 7-column grid, 6 px gaps; leading/trailing
blank cells to square the grid; one 72 px-tall button cell per calendar day
(from the densified month):
- Top: day-of-month number, 11 px tabular — today: semibold accent; tracked
  (workedMs > 0): fg-muted; untracked: fg-faint.
- Middle: `formatCompact(workedMs)` if > 0 else `—`; a 6 px `work`-green dot on
  the right when target met (`targetMs > 0 && workedMs >= targetMs`, per-day
  stamped target).
- Bottom: 2 px progress hairline — fill `min(1, worked/target)`, `work` when
  met else `accent`; empty when no target.
- Styling: selected → `accent-soft` bg + `accent` border; today (unselected) →
  `accent/60` border; weekend → `sunken` bg; hover brightens border only.
  Accessibility label: `{formatDateLong(date)} — {…h …m worked|nothing
  tracked}{, target met}`.
- Click selects the day (never changes the month).

**List view**: same densified month, **newest first**. Columns
`Day | Worked | Break | First | Last` (header uppercase 10 px). Per row: day
`formatDateLong` (+ `Today` chip when today; dimmed when untracked — here
tracked = workedMs > 0 **or** breakMs > 0, deliberately different from the
calendar); worked `formatCompact` + met-dot or `—`; break `formatCompact` in
break color or `—`; first `formatClock(firstStartAt)` or `—`; last
`formatClock(lastEndAt)`, or **`now`** when `hasOpenSegment`, else `—`. Rows are
selectable buttons. When the month has no data at all, the list shows only the
empty-state card (the calendar still renders beneath its empty state).

**Day detail column**: fixed **340 px** right aside, border-l, raised bg, own
1 s tick recomputing `dayTotals` live:
- Header: `formatDateLong(date)` 14 px semibold + `Today` chip; hero
  `formatHM(workedMs)` at 38 px light tabular; caption: no target → `worked`;
  met → `target met · +{formatCompact(worked − target)}` in work green; else
  `of {formatCompact(targetMs)}` fg-muted. Target = day's stamped
  `targetMinutes`, falling back to the current preference for a day with no
  row. ProgressBar (6 px, same rules as panel) when target > 0. Meta line
  (11 px fg-faint): `{first|—} – {last|now|—}`, `{n} segment{s}` (singular at
  1), `{formatCompact(breakMs)} break`.
- Sub-header: uppercase `Segments` label + small `Add segment` button.
- Body: SegmentRow list with hover-revealed **Edit segment** / **Delete
  segment** icon buttons (pencil/trash, 24 px, danger hover on delete); or
  empty state `Nothing on this day` / `Add a segment by hand to record time the
  timer missed.`

**Add/Edit segment modal**: title `Add segment` / `Edit segment`; footer ghost
`Cancel` + primary `Add segment` / `Save changes` (disabled while saving; Enter
submits; Escape closes unless saving). Body: date caption `formatDateLong`;
`Type` segmented `Work`/`Break`; `Start` and `End` time fields (`HH:MM`);
`Note (optional)` text field, max 200 chars, placeholder
`What was this time for?`; inline error box. Defaults for a new segment: start =
day's `lastEndAt`, else 09:00 local, else start of day; end = start + 1 h.
Rules:
- End < start → treated as overnight, end resolves on the next day, with live
  notice: `The end time is before the start, so this segment is treated as
  running past midnight and ends on {formatDateLong(date+1)}.` Equal instants
  are NOT nudged overnight (zero length is a real error).
- Editing the currently open segment with End empty shows: `This segment is
  still running. Leave the end time empty to keep it open, or set one to close
  it here.` (Only the open segment may be left open; create requires an end —
  error `Enter an end time.`)
- Field errors: `Enter a start time as HH:MM.` / `Enter an end time as HH:MM.`
- Engine errors surface verbatim (see §3.6 plus): `That segment no longer
  exists.`, `Another segment is still running.` (re-opening while another is
  open), `That segment could not be read.` / `That edit could not be read.`
  (malformed), `The day could not be read back.` Rejection fallback: `The
  segment could not be saved.`
- Create semantics: split at midnight; validate against every affected day's
  segments; insert each piece under its own day (same note on all); the
  addressed day row is created even if every piece lands elsewhere; per-day
  target for auto-created days = current preference.
- Update semantics: absent field = untouched; explicit null end reopens;
  affected dates include the row's original date plus all piece dates;
  validation excludes the edited row's own id; if the head piece stays on the
  same day, update in place, else delete + re-insert (rows never move between
  days); later pieces are new rows. Returns the head piece's day.
- On success: close, refetch; move the selection to the returned day **only if
  it lies inside the visible month**.

**Delete flow**: modal `Delete this segment?`; body `This removes the
{work|break} segment from {HH:MM} to {HH:MM|now}. The time it recorded is gone
for good.`; ghost `Cancel` + danger `Delete` (disabled while deleting). Errors
inline: `That segment no longer exists.`, `Stop the timer before deleting the
segment it is still writing to.` (open segment), `That segment could not be
identified.`; rejection fallback `The segment could not be deleted.`

**Export**: range = the visible month, always. Save panel: title
`Export Deylee data`, default filename `deylee-{from}_to_{to}.{csv|json}`,
CSV/JSON type filter, sheet on the History window. Cancel → no UI at all.
Success → banner `Saved to {path}`; error → banner with the message; rejection
fallback `The export could not be written.` Export does **not** trigger
invalidation. Only DB-resident days are exported (no densification); a day row
with zero segments emits one near-empty CSV row.

- **CSV**: header exactly
  `date,segment_type,started_at_local,ended_at_local,duration_minutes,started_at_utc_ms,ended_at_utc_ms,note`.
  Days ascending, segments ascending. Local times `HH:MM:SS` 24-hour.
  `duration_minutes` = `(end − start)/60000` clamped ≥ 0, max 2 decimals,
  trailing zeros dropped (`60`, `0.67`). An open segment leaves
  `ended_at_local`, `duration_minutes`, `ended_at_utc_ms` empty ("now" is never
  baked into a file). RFC 4180 quoting only when a field contains
  `"`/CR/LF/comma (internal quotes doubled); LF line endings, no trailing
  newline.
- **JSON**: pretty-printed (2-space)
  `{ exportedAt: ISO-8601 UTC, range: {from, to}, days: [{ date, targetMinutes,
  totals: DayTotals, segments: Segment[] }] }` — totals computed at export time,
  segments as full stored objects.

**Empty/error states**: month load failed → `History could not be read` /
`Deylee could not reach its local database. Close and reopen this window to try
again.`; empty month → `Nothing tracked in {Month Year}` / `Days appear here
once you track time. You can still add a segment by hand from the day panel.`
Week fetch failure just leaves the Week stat at `—` (no error UI).

### 5.5 Settings window

**Window**: 560 × 640, min 480 × 420, resizable, standard title bar, Dock
visible while open. One instance; closing destroys it. Content **scrolls**
vertically rather than the window growing.

**Header** (sticky, border-b, space-between): title `Settings` (semibold);
right, the SavedNote — polite live region, 12 px, 500 ms opacity fade, visible
for **1 800 ms** per flash (rapid edits restart the timer): success = check
icon + `Saved` in faint fg; failure = `Could not save` in danger. There is no
Save button — every control writes through immediately; the engine
clamps/persists and the control adopts the **returned** (clamped) value, so a
refused write snaps the control back.

**Body**: while preferences load — `Loading your preferences…` (small, faint);
then sections at 24 px gaps. Section = uppercase 11 px semibold faint heading +
optional 12 px muted description + a rounded-xl bordered raised card with
hairline-divided rows (px 8 / py 8 rhythm).

Sections, rows, and exact copy (top to bottom):

**Account** — "Sign in to keep your hours on every device. Deylee works fully
without it." The first group, reachable whether or not sign-in was skipped at
launch. Always **one row, one trailing button**, in four states of the same shape so
the row never jumps as it moves between them; the Sign in button raises the same
window credentials are typed in (§11 of the UI spec) — there is never a second,
smaller form to maintain.

| State | Title | Detail | Action |
|---|---|---|---|
| signed out / failed | `Not signed in` | `Log stays on this machine only` | `Sign in` (prominent) |
| signing in | `Waiting for your browser…` | `Finish in the window that opened` | `Cancel` |
| needs transfer confirmation | the email | `Confirm moving this machine's history over` | `Review` (prominent) |
| signed in | the email | sync detail, below | `Sign out` |

Sync detail, signed in — `{state} · {provider}`, provider falling back to
`Account`: idle → `Waiting for the next check`; syncing → `Syncing…`; succeeded →
`Synced {relative} ago`; failed → `Sync paused`; rejected → the single reason
verbatim, or `{n} changes were refused`. The provider is named because somebody
with both a Google and a password route needs to know which one this session came
from.

A **second row appears only while sync is actually failing** — title `Sync paused —
offline` when the reason mentions offline/connect, else `Sync paused`; detail
`Tracking continues; will catch up`; warning tone; action `Retry`. It is a separate
row deliberately: "your account" and "sync is behind" are different facts, and
burying the second inside the first is how people miss it. When sync is healthy the
row is absent rather than present-and-empty.

**General** — "How Deylee starts up and how it looks."
1. **Launch at login** (toggle, `launchAtLogin`, default off) — "Starts Deylee in
   the background when you sign in." Semantics: OS registration
   (SMAppService) is applied and awaited **before** persisting; an OS refusal
   leaves the preference untouched and flashes "Could not save". Read-back
   treats `requiresApproval` as **off** (reports what will actually happen at
   next login). **Startup reconciliation: the OS is the truth** — if the stored
   pref differs from the OS state at launch, the pref silently follows the OS
   (never re-register behind the user's back); if the OS can't be read, leave
   the pref alone.
2. **Show the mini window** (toggle, `showMiniWindow`, macOS default off) — "A
   small always-on-top clock. The menu bar already shows your running time, so
   this is optional." Applies live (creates/destroys the mini window).
3. **Appearance** (segmented `System | Light | Dark`, `theme`, default System)
   — "System follows your desktop's light or dark setting." All windows
   re-theme simultaneously. Swift: `NSApp.appearance = nil / .aqua / .darkAqua`.
4. **Week starts on** (segmented `Sunday | Monday`, `weekStartsOn`, default
   Monday) — "Used by the week totals in History."

**Tracking** — "Your target, and when Deylee should question the time it is
counting."
5. **Daily target** (number field, `dailyTargetHours`, default 8; min 0, max
   24, step 0.5, suffix "hours"; decimals allowed, clamped, never rounded) —
   "Drives the progress bar and the target-met markers in History." On change:
   re-stamp **only today's** day row (compared in minutes; no-op when equal or
   no row yet), invalidate today, emit a snapshot. Past days are never
   rewritten.
6. **Detect when you step away** (toggle, `idleDetectionEnabled`, default on)
   — "While the timer runs, Deylee watches how long the machine has been
   untouched and asks whether to keep the time."
7. **Ask after** (number field, `idleThresholdMinutes`, default 10; min 1, max
   240, step 1, suffix "minutes"; disabled when detection is off) — enabled:
   "How long the machine must sit untouched before Deylee asks."; disabled:
   "Turn on "Detect when you step away" to change this."
8. **Pause when the computer sleeps** (toggle, `autoPauseOnSleep`, default on)
   — "The gap is held until you are back, then you choose whether it was a
   break."
9. **Pause when the screen locks** (toggle, `autoPauseOnLock`, default off) —
   "Off by default — a lock during a call or a screensaver is not always a
   break."

**Reminders** — "One nudge a day, and only while the timer is still running."
10. **Remind me to stop** (toggle, `reminderEnabled`, default off) — "Fires at
    most once per day, at the time below."
11. **Reminder time** (native time input showing `HH:MM`, default 17:30;
    disabled when reminders off) — enabled: "Local time, on a 24-hour clock or
    your locale's equivalent."; disabled: "Turn reminders on to choose a time."
    One field writes two preferences (`reminderHour` then `reminderMinute`,
    sequentially); incomplete mid-edit values are ignored, never half-written.

**Data** — "Your database lives on this machine. Signed out, it goes nowhere;
signed in, your hours sync to your account and nothing else does."

(This copy was *"Everything Deylee records stays on this machine. Nothing is ever
uploaded."* It stopped being true the moment sync existed and is recorded here
because this is the screen where somebody checks. Copy that quietly contradicts the
software is worse than no copy at all. If a future feature widens what leaves the
machine, this string changes in the same commit — not after.)
12. **Data folder** info block — title "Data folder", description "Your
    database and preferences live here.", then the absolute folder path in a
    selectable monospace 12 px box (truncated, full path in tooltip;
    placeholder `Locating…`).
13. Buttons: **`Reveal in file manager`** — Finder with `deylee.sqlite` selected
    (`NSWorkspace.activateFileViewerSelecting`); failures swallowed.
    **`Back up database…`** — becomes `Backing up…` while busy; flow per §2.7.
    Success → 12 px line in work green: `Backed up to {path}` (monospace,
    selectable). Error → danger line with the message; renderer-start fallback
    `The backup could not be started.` Cancel → silently back to idle.

**Updates** — description (capable): "A version check against the project's
public releases page. No account, no telemetry, no payload." — (not capable):
"This build has no update feed, so Deylee never checks. New versions live on the
project's public releases page."
14. **Check for updates automatically** (toggle, `updateCheckEnabled`, default
    on; **disabled when the build cannot auto-update**) — capable: "Deylee's
    only network request. Nothing is downloaded without asking."; not capable:
    "This build has no update feed, so there is nothing to check on a schedule.
    Deylee makes no network request either way." The shipped Electron mac build
    has `canAutoUpdate = false` (unsigned), reason copy: `Automatic updates
    need a signed build — check the Releases page.` Manual "Check now" runs
    even when the pref is off (pressing the button is consent for that one
    request). Schedule (when capable): first check 10 s after launch, then
    every 6 h via chained timeouts, pref re-read at each boundary.
15. **Version row** — label `Version {currentVersion}` (bare `Version` until
    known). Control: a compact one-line status + at most one action (message
    max-width ~19 rem; link-styled action = leaves the app; real button =
    Deylee does it itself; never green; no animation):

    | status | message | action |
    |---|---|---|
    | idle | `Not checked yet` | `Check now` |
    | checking | `Checking for updates…` | — |
    | up-to-date | `Up to date · v{version}` (or bare `Up to date`) | `Check now` |
    | available | `Version {v} is available` | `Download` (capable) / link `Open Releases` |
    | downloading | `Downloading… {p}%` | — |
    | downloaded | `Version {v} is ready` | `Restart to update` |
    | manual | `Version {v} is available — this build can't install it for you` | link `Open Releases` |
    | unsupported | the reason string | link `Open Releases` |
    | error | `Couldn't check for updates` (detail in tooltip) | `Try again` |

    Error-string mapping: network failures → `Could not reach GitHub. Deylee
    will try again later.`; download before check → `There is nothing to
    download yet — check for updates first.`; dev build → `Updates are only
    checked in an installed build.`; missing feed → `This build has no update
    feed — check the Releases page.`; generic → first line truncated to 200
    chars + `…`; empty → `The update check failed.`; couldn't even start →
    `The update check could not be started.`

Not in the UI (bookkeeping only): `miniWindowPositions`,
`trayFallbackNoticeShown` (Linux-only). A reset-to-defaults exists in the
engine but has no UI (see §9).

---

## 6. Design tokens

**Dark is the primary theme.** Theme preference `system | light | dark`; an
explicit choice always beats the OS appearance. Never hard-code a hex — always
tokens. **Green (`work`) is reserved exclusively for the running/work state**;
the `accent` used for primary buttons/selection is a NEUTRAL (near-black in
light, near-white in dark).

### 6.1 Palette (exact; light / dark)

| Token | Light | Dark | Meaning |
|---|---|---|---|
| surface | `#f2f2ef` | `#141416` | window base |
| raised | `#ffffff` | `#232326` | card/panel fill |
| sunken | `#f7f7f5` | `#18181b` | recessed fill (tracks, modal footers) |
| hover | `#ececea` | `#2e2e33` | hover fill |
| border | `#e0e0dc` | `#35353a` | hairline |
| border-strong | `#d8d8d4` | `#47474e` | strong border, default focus ring, scrollbar thumb |
| fg | `#1c1c1e` | `#ebebef` | primary text |
| fg-muted | `#6b6b70` | `#a0a0a8` | secondary text |
| fg-faint | `#98989e` | `#6e6e76` | tertiary / caps labels |
| fg-dim | `#8e8e94` | `#8b8b93` | hero seconds |
| fg-ghost | `#c2c2c6` | `#4a4a52` | disabled numerals |
| accent | `#1c1c1e` | `#ebebef` | neutral primary fill (= fg) |
| accent-hover | `#33333a` | `#ffffff` | primary hover |
| accent-fg | `#ffffff` | `#18181a` | label on accent |
| accent-soft | `#ececea` | `#2e2e33` | selection bg, selected cells |
| work | `#2f8a72` | `#4fbfa0` | running green |
| work-soft | `rgb(47 138 114 / .14)` | `rgb(79 191 160 / .16)` | work chip fill |
| break | `#8c6a2a` | `#c79a54` | break amber |
| break-soft | `rgb(140 106 42 / .14)` | `rgb(199 154 84 / .16)` | break chip fill |
| danger | `#c0392b` | `#e05c53` | destructive |
| danger-soft | `rgb(192 57 43 / .12)` | `rgb(224 92 83 / .16)` | danger fill |
| shadow (panel) | `0 10px 30px rgb(0 0 0 / .13)` | `0 18px 44px rgb(0 0 0 / .5)` | modal/panel shadow |

(Secondary-button/titlebar/calendar-cell auxiliary tokens exist in the CSS but
components resolve to the semantic set above.)

### 6.2 Typography

System font (SF Pro on macOS — never a bundled font). Base 13 px / 1.4,
antialiased. **Tabular (monospaced) digits on everything that ticks or stacks**
— `.monospacedDigit()` / `NSFont.monospacedDigitSystemFont`.

| Role | Spec |
|---|---|
| Panel hero | 300 weight, 52 px / 1, tracking −0.02 em; `:SS` at 0.5 em (26 px), normal tracking, `fg-dim` |
| History day hero | 300, 38 px / 1 |
| Mini timer | 400, 22 px / 1 |
| History month title | 500, 17 px |
| Stat values | 500, 15 px |
| Body | 400, 13 px / 1.4 |
| Small/meta | 12 px; 11.5 px (update line); 11 px (hints, panel header) |
| Caps labels | uppercase, 10–11 px, 500–600, tracking 0.05–0.12 em, `fg-faint` |

Weights used: 300 (heroes only), 400, 500 (the workhorse), 600 (caps labels,
modal titles). No bold.

### 6.3 Spacing, radii, shadows

- Spacing: 4 px grid; observed steps 2/4/6/8/10/12/14/16/20/24/40.
- Radii (as shipped): window/panel/modal **10 px**; buttons/rows/inputs **8 px**;
  chips/steppers/small icons **6 px**; settings cards and the mini card
  **12 px**; full-round for dots, toggles, progress bars, compact circle button.
  (Declared-but-unused tokens: control 7 px, chip 4 px, mini 13 px — see §9.)
- Shadows: panel shadow (table above) on modals only; primary buttons carry a
  small accent-tinted shadow; toggle knob a small shadow.

### 6.4 Motion

Deliberately minimal: **no scale transforms, no bounce, no pulsing, no sound, no
tray-icon animation.** As shipped: color transitions **150 ms** on every
interactive control; ProgressBar width+color **500 ms ease-out**; toggle-knob
translate **150 ms ease-out**; hover-action opacity 150 ms. Nothing else
animates. (DESIGN.md's 120/80/180 ms set is an open question.)

### 6.5 Control specs (as shipped)

- **Button**: variants primary (accent fill / accent-fg label / hover
  accent-hover), secondary (border + raised fill), ghost (muted text, hover
  fill), danger (danger-soft fill + danger border/text, hover solid danger with
  white text). Sizes: sm 28 px h / 12 px text; md 36 px / 14 px; lg 44 px /
  15 px. Disabled: 45 % opacity, inert.
- **Toggle**: whole row is the switch; track 36 × 20 px pill — on `accent`, off
  `fg-faint` at 35 % (ink tint, not a surface, so the white 14 px knob keeps
  contrast in both themes); knob slides 16 px, 150 ms.
- **NumberField**: bordered raised cluster (focus ring on the border) of
  − stepper / 48 px centered text field / suffix / + stepper (28 px steppers,
  disabled at bounds). Draft committed on blur/Enter (clamped); Escape reverts;
  empty/NaN reverts silently; steppers commit ± step immediately.
- **Segmented control**: sunken bordered container; 28 px items; selected =
  raised fill + full fg + small shadow; clicking the selected option does
  nothing (no no-op write, no unearned "Saved").
- **ProgressBar**: 6 px rounded track in `sunken`; fill clamped 0–1, `accent` →
  `work` at ≥ 1; ARIA progressbar 0–100.
- **EmptyState**: dashed 1 px border, 10 px radius, centered, generous padding;
  14 px medium `fg-muted` title; 12 px `fg-faint` description max ~32 ch.
- Focus ring: 2 px, offset 2; `accent` on controls (default `border-strong`
  elsewhere — the neutral accent would vanish on light surfaces).
- Scrollbars: thin overlay style (the 320 px panel cannot spare 15 px).
- Chrome text is non-selectable, default cursor; inputs opt back in.

### 6.6 Iconography and app icon

- In-UI glyphs: inline vector, 16-unit viewBox, `currentColor`, typically 14 px:
  Play `M5.2 3.1v9.8a.7.7 0 0 0 1.07.6l7.3-4.9a.7.7 0 0 0 0-1.2l-7.3-4.9a.7.7 0 0 0-1.07.6Z`;
  Pause: two rects x=4|9 y=3 w=3 h=10 rx=1.2; plus minus/plus, pencil, trash, X.
- Menu-bar template glyph: §5.1 clock geometry.
- App icon **as shipped**: rounded-rect field (inset 32/1024, corner radius
  216/1024) filled with a diagonal indigo gradient `rgb(129,140,248)` →
  `rgb(67,56,202)`, radial white highlight top-left (center alpha 54/255,
  quadratic falloff), and a centered white clock mark (ring outer 360/1024,
  thickness 64/1024; minute hand up 240/1024; hour hand right 168/1024; hand
  half-width 24/1024; center dot 38/1024). DESIGN.md §9 specifies a different
  mark (grey dial, single green arc) — open question.

---

## 7. Settings — storage and runtime effects

Storage: the Electron app persists preferences as a flat JSON file
`preferences.json` (electron-store) beside the DB. The file is treated as
untrusted: **every value is validated and clamped on read AND write, per key**
(one bad field never resets the rest); rejected values fall back to the
**current** value, not the default. `miniWindowPositions` writes merge per
display. A full-store reset to defaults exists in the engine (no UI). Every
successful write notifies all surfaces (re-theme, mini sync, login-item safety
net, today-target re-stamp).

Coercion rules: booleans strictly boolean; numbers clamp (no rounding for
`dailyTargetHours`; rounding for integer prefs); enum membership for
theme/weekStartsOn (`weekStartsOn`: any number ≥ 1 rounds to 1, else 0);
positions per-entry finite-and-rounded, malformed entries dropped individually.

| Key | Type / range | Default (macOS) | Runtime effect |
|---|---|---|---|
| `launchAtLogin` | bool | `false` | SMAppService register/unregister; OS-first write ordering; startup reconciliation with the OS as truth (§5.5 #1). |
| `showMiniWindow` | bool | `false` | Mini window exists ⇔ pref on; applied live on every change. |
| `idleDetectionEnabled` | bool | `true` | Gates the 15 s idle poll (read fresh each poll). |
| `idleThresholdMinutes` | int 1–240 | `10` | Idle threshold; read fresh each poll. |
| `autoPauseOnSleep` | bool | `true` | Gates sleep-away handling and the watchdog. |
| `autoPauseOnLock` | bool | `false` | Gates lock-away handling. |
| `dailyTargetHours` | number 0–24, fractional, not rounded | `8` | New day rows stamp `round(h×60)` minutes; change re-stamps today only; drives progress bars and target-met markers. |
| `reminderEnabled` | bool | `false` | Gates the reminder tick. |
| `reminderHour` | int 0–23 | `17` | Reminder due time (local). |
| `reminderMinute` | int 0–59 | `30` | 〃 |
| `theme` | `system\|light\|dark` | `system` | App-wide appearance, all windows at once. |
| `weekStartsOn` | `0\|1` | `1` (Monday) | History week roll-up + calendar column order. |
| `miniWindowPositions` | `{displayId: {x,y}}` | `{}` | Per-display mini position memory (no UI). |
| `trayFallbackNoticeShown` | bool | `false` | Linux-only bookkeeping — NOT APPLICABLE. |
| `updateCheckEnabled` | bool | `true` | Gates the scheduled update check (the app's only network call); manual check runs regardless. |

Error surface: a preference write is the **only** operation allowed to fail
loudly — unknown key, wrong type, or OS refusal (login item) rejects; the UI
flashes "Could not save" and the control snaps back to the engine's value.
Message shape: `Could not save "{key}": unknown preference, or wrong type.`

---

## 8. Porting map (Electron/Chromium → Swift/AppKit/SwiftUI)

| Electron mechanism | Swift counterpart |
|---|---|
| Main process + preload bridge + IPC channels (`window.deylee`) | Collapses into one process: a timer-engine/repository core (actor or serial-queue-confined) plus `@Observable`/Combine streams to the UI. Keep the **payload shapes, error-as-value semantics (`MutationResult`, file-write results with a distinct "cancelled" case), fallback behaviors, and event pairing (invalidate + snapshot)** identical. The channel-name allow-list, payload narrowing, `windowKind`, and `dismissNotice` plumbing disappear. |
| better-sqlite3 (SQLite 3.53.x), WAL, prepared statements | GRDB or raw sqlite3; same pragmas (§2.2), same SQL semantics, SAVEPOINT-nested transactions, single writer. |
| SQLite online backup via a second read-only connection | `sqlite3_backup_init/step/finish` (or `VACUUM INTO`) from a second read-only connection; close it in a defer. |
| electron-store `preferences.json` | `UserDefaults` or a JSON file — keep per-key validate/clamp-on-read-and-write semantics either way (see §9 for which store). |
| `Tray` / native NSStatusItem addon | `NSStatusItem` directly: variable length, `sendAction(on: [.leftMouseUp, .rightMouseUp])`, secondary = right up/down or control-click, temporary menu attach + `performClick` + next-runloop detach, `autoenablesItems = false`, `button.isHighlighted` tracks panel visibility (synchronous in-process; the Electron build's optimistic deferred toggle only hid a JS round-trip). Set the template image once. |
| Panel `BrowserWindow` (`type:'panel'`, frameless, blur-to-hide) | Non-activating `NSPanel` (`.nonactivatingPanel`) at a status-bar-ish level, 320 × 436 content, positioned 8 pt under the item centered on it, clamped to `visibleFrame`; hide on resign-key/outside click; keep the instance alive when hidden. (Or NSPopover, accepting its anchoring; see §9 prompt-pinning question.) |
| Mini `BrowserWindow` (transparent, alwaysOnTop 'floating', visibleOnAllWorkspaces) | Borderless `NSWindow`/`NSPanel`: `isOpaque = false`, clear background, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`, `orderFrontRegardless()` (never make-key), `isMovableByWindowBackground = true`; blur via `NSVisualEffectView` / `.ultraThinMaterial` with 12 pt rounded mask + 1 px border. Flip Electron's top-left-origin stored coordinates to AppKit. |
| `windows:mini-moved` IPC + main-side move debounce | Observe `NSWindow.didMoveNotification`, debounce ~300 ms, persist `{x,y}` keyed by `CGDirectDisplayID` (`NSScreen.deviceDescription[.init("NSScreenNumber")]`); the renderer-side redundant path disappears. |
| `app.dock.hide()/show()` + `LSUIElement` | `LSUIElement = true` in Info.plist; `NSApp.setActivationPolicy(.accessory)` at launch, `.regular` while History/Settings is open, back to `.accessory` when the last closes. |
| History/Settings `BrowserWindow`s | Ordinary resizable `NSWindow`s (900×640 min 760×520; 560×640 min 480×420), single-instance reuse-and-focus. |
| `powerMonitor.getSystemIdleTime()` | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kCGAnyInputEventType)` × 1000. Keep the null branch as dead-safe. |
| `powerMonitor` `suspend`/`resume` | `NSWorkspace.shared.notificationCenter` — `willSleepNotification` / `didWakeNotification`. |
| `powerMonitor` `lock-screen`/`unlock-screen` | `DistributedNotificationCenter.default()` — `"com.apple.screenIsLocked"` / `"com.apple.screenIsUnlocked"`. |
| Wall-clock sleep watchdog | Keep for parity (`DispatchSourceTimer` + `Date()` comparison — deliberately wall clock, not monotonic). |
| `app.setLoginItemSettings` / `getLoginItemSettings` | `SMAppService.mainApp.register()/unregister()`; enabled ⇔ `.enabled`; map `.requiresApproval` to off. Keep OS-first write ordering and startup reconciliation. Requires macOS 13+ (see §9). |
| `new Notification()` + click handler | `UNUserNotificationCenter` with a click action that opens the panel. Needs authorization Electron never asked for — prompts must reach the panel regardless (notifications are already optional in the design); see §9. |
| `shell.showItemInFolder` | `NSWorkspace.shared.activateFileViewerSelecting([url])`. |
| `shell.openExternal(releasesUrl)` | `NSWorkspace.shared.open(url)`. |
| `dialog.showSaveDialog` | `NSSavePanel` (sheet on the owning window): `nameFieldStringValue`, `allowedContentTypes`, `canCreateDirectories`; overwrite confirmation is default. |
| `electron-updater` + GitHub feed | Keep the status vocabulary of §5.5 #15. Shipped behavior = manual flow (unsigned build); a signed Swift app could adopt Sparkle — open question. |
| Theme classes + `matchMedia` | `NSApp.appearance = nil / NSAppearance(named: .aqua) / .darkAqua`; SwiftUI `preferredColorScheme`. |
| `setInterval` ticks (1 s/10 s/15 s/30 s/60 s) | `Timer`/`DispatchSourceTimer` on the main run loop; `TimelineView(.periodic)` for the 1 Hz displays. macOS timer coalescing tolerance is already covered by the watchdog's 60 s threshold. Re-sync displays on window key/occlusion changes (the Electron build re-syncs on visibility/focus because throttled windows stall). |
| JS local-`Date` calendar math | `Foundation.Calendar` + `TimeZone.current`: `startOfDay(for:)` (matches JS on nonexistent midnights), `date(byAdding:)`, `dateComponents(_:from:to:)`. Ship a DST test suite (23 h/25 h days; America/Santiago midnight spring-forward → start-of-day 01:00). |
| Single-instance lock / `second-instance` | LaunchServices makes bundles effectively single-instance; handle reopen (dock/Finder relaunch) by surfacing the panel. |
| Drag regions (`-webkit-app-region`) | Irrelevant in a popover; `isMovableByWindowBackground` on the mini. |
| Renderer sandboxing/CSP, asar, native addon loader, Linux tray fallback, snap idle probing, Windows/Linux tray art & platforms | NOT APPLICABLE. |

`PlatformInfo` equivalents on macOS are constants: tray available, tray title
supported, lock detection supported, idle detection supported, tray fallback
never active, mini default off.

---

## 9. Open questions

Merged and deduplicated across all surveys. **Q1 is the umbrella decision; many
smaller ones fall out of it.**

**Fidelity and design authority**

1. **DESIGN.md vs shipped code.** CLAUDE.md declares `docs/DESIGN.md` binding,
   but the shipped app diverges substantially: no macOS vibrancy on the panel;
   solid status dot + label instead of the 2 px state hairline + `DEYLEE`
   wordmark; 6 px progress bar vs 3 px (with hatched paused states specced but
   absent); chip-style segment rows vs quiet dot rows; two-choice idle prompt vs
   the specced three-choice (`convert-to-break`); in-panel modals vs 380 px
   translucent prompt cards; toggle 36×20 vs 38×22; button radius 8 vs 7;
   motion 150 ms uniform vs 120/80/180; mini window far simpler than §5's spec
   (8 px dot vs 11 px dot + halo/break bars, no progress hairline, no dashed
   paused border, no hover-opacity glyph, no edge snapping, H:MM vs H:MM:SS,
   radius 12 vs 13); Settings sections entirely different (no
   `trayLabelFormat`, no `confirmBeforeEndDay`). **Which is the rewrite's
   target?** This spec documents the shipped code; every DESIGN.md-only feature
   above is otherwise out of scope.
2. **App icon**: shipped indigo-gradient + white clock vs DESIGN.md's grey dial
   with a single green arc — which mark goes in the asset catalog?
3. **Tray art**: shipped single static clock template (state carried by title
   text) vs DESIGN.md's shape-per-state monochrome marks + `trayLabelFormat`
   preference — which behavior?

**Data and identity**

4. Should the Swift app **adopt** `~/Library/Application Support/deylee/` as its
   live store, or **one-time-import** (via the backup API) into its own
   container? This decides whether both apps can ever run against the same file.
5. Will the Swift app be **sandboxed**? If yes, reading the Electron DB needs an
   NSOpenPanel grant or temporary exception; if no, direct import works.
6. Reuse bundle id `me.faizraza.deylee` or take a new one? (The Electron build is
   unsigned, so no signing conflict either way; login-item and defaults
   continuity favor reuse.)
7. Is importing `preferences.json` in scope, or only the SQLite data? Related:
   should Swift preferences live in `UserDefaults` or a JSON file beside the DB
   (the Settings copy says "Your database and preferences live here")?
8. If the Swift app later migrates the schema past v1, is bidirectional
   compatibility with the Electron app required (which refuses anything > 1 by
   design), or is import one-way?
9. Minimum macOS version: the native addon targeted 11.0, but SMAppService
   needs 13+. Target 13+, or implement a legacy login-item fallback for 11–12?

**Behavioral parity judgment calls**

10. **Auto-update**: the shipped mac build is permanently in the manual flow
    (unsigned → `canAutoUpdate = false`, schedule toggle disabled, "Open
    Releases" only). A signed/notarized Swift app could adopt Sparkle. Replicate
    the disabled/manual behavior exactly, or enable real auto-update (changing
    the toggle, descriptions and status states)?
11. **Notification permission**: UNUserNotificationCenter requires authorization
    Electron never requested. On denial — silently rely on in-panel prompts
    alone (the design already treats notifications as optional), or surface the
    missing permission in Settings?
12. **Sleep watchdog**: exists chiefly for platforms with unreliable
    suspend/resume events; NSWorkspace notifications are reliable. Keep for
    exact parity (it also nets missed events and clock jumps — recommended), or
    drop?
13. **endDay vs recovery-close asymmetry** on a backwards clock jump
    (`now <= startedAt`): endDay closes zero-length, recovery-close deletes.
    Intentional, or normalize both to delete?
14. **ReminderService `lastFiredOn` is in-memory only** — relaunching after the
    reminder fired can re-fire it the same day. Replicate the quirk or persist?
15. **Panel height**: fixed 436 pt with internal whitespace in shorter states
    (what ships) or content-driven 372–436 (what DESIGN.md implies)?
16. **Prompt modals vs popover dismissal**: the Electron panel hides on blur
    with an unanswered mandatory prompt still queued. Acceptable for the Swift
    popover/panel too, or pin it open while a prompt is pending?
17. **"Open Deylee" quirk**: the tray-menu item opens the panel un-anchored
    (centered on the primary display if freshly created); only the left-click
    path anchors under the icon. Reproduce, or always anchor? (In-process Swift
    can always fetch the item bounds trivially.)
18. **24-hour clocks**: `formatClock` forces `HH:MM` regardless of the user's
    12/24-hour locale setting. Keep forced 24-hour, or adopt DateFormatter
    locale behavior?
19. **CSV export densification**: only DB-resident days of the month are
    exported (a day row with zero segments emits one near-empty row; absent
    days emit nothing). Keep exactly, or densify?
20. **`prefs` reset-to-defaults** exists in the engine with no UI — add an
    affordance or omit entirely?
21. **"Loading your preferences…"** state exists only because prefs load over
    async IPC; a native app reading synchronously would never show it.
    Replicate or drop?
22. **Snapshot push cadence**: a stale docstring says snapshots fire "on the
    30 s heartbeat"; the code emits only on transitions/rollover/mutations,
    with renderers ticking locally at 1 Hz. Confirm state-change-only (what the
    code does) is the contract.
23. **`firstStartAt` is un-clipped**: while yesterday's open segment awaits the
    rollover tick (≤ 1 s), today's snapshot can report a `firstStartAt` from the
    previous day. Confirm no UI depends on this beyond the self-correction.
24. **Unused bridge surface**: `windows.close`, `windowKind`, and the
    `dismissNotice` round-trip are exposed but unused/no-op — they vanish
    naturally in a single-process app; confirm nothing else is expected of them.
25. **Unused radius tokens**: mini 13 px, control 7 px, chip 4 px are declared
    but the shipped UI renders 12/8/4–6 px. Which values govern (subsumed by
    Q1)?
26. **DST parity bar**: how exact must `Calendar` vs JS `Date` parity be for
    non-default timezones (nonexistent midnights, 23 h/25 h days)? A dedicated
    test suite (America/Santiago et al.) is assumed; confirm it is a hard
    requirement.

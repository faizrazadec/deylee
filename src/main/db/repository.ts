/**
 * Every read and write of the SQLite file goes through this class.
 *
 * Three invariants shape it:
 *  - **No total is ever stored.** `getDayDetail` / `getRange` derive `DayTotals`
 *    with `dayTotals()`, so a crash, a manual edit or a clock change can never
 *    leave a stale number behind.
 *  - **Every stored segment belongs to exactly one local day.** That is why closing
 *    a segment goes through `closeSegmentSplitting` instead of a plain UPDATE.
 *  - **At most one segment is open app-wide**, which `findOpenSegment` relies on.
 *
 * Everything is synchronous: better-sqlite3 has no async API, and the main process
 * does not benefit from one for a local file this small.
 */

import type Database from 'better-sqlite3';
import { dayTotals } from '@domain/duration';
import { splitAtMidnight } from '@domain/midnight';
import type {
  DateKey,
  DateRange,
  Day,
  DayDetail,
  EpochMs,
  Segment,
  SegmentType,
} from '@shared/types';

/** Where `HeartbeatService` records the last instant the app was known to be alive. */
export const APP_STATE_HEARTBEAT = 'heartbeat_at';

/* -------------------------------------------------------------------------- */
/* Rows                                                                        */
/* -------------------------------------------------------------------------- */

/**
 * The exact shape each SELECT returns. Columns are listed explicitly in the SQL
 * (never `SELECT *`) so these interfaces stay truthful as the schema grows.
 */
interface DayRow {
  id: number;
  date: string;
  created_at: number;
  ended_at: number | null;
  target_minutes: number;
}

interface SegmentRow {
  id: number;
  day_id: number;
  type: string;
  started_at: number;
  ended_at: number | null;
  note: string | null;
  created_at: number;
  updated_at: number;
}

/** One row of the days⨝segments range query; the segment side is null-filled. */
interface DayJoinRow {
  day_id: number;
  day_date: string;
  day_created_at: number;
  day_ended_at: number | null;
  day_target_minutes: number;
  segment_id: number | null;
  segment_day_id: number | null;
  segment_type: string | null;
  segment_started_at: number | null;
  segment_ended_at: number | null;
  segment_note: string | null;
  segment_created_at: number | null;
  segment_updated_at: number | null;
}

interface AppStateRow {
  value: string;
}

const DAY_COLUMNS = 'id, date, created_at, ended_at, target_minutes';
const SEGMENT_COLUMNS = 'id, day_id, type, started_at, ended_at, note, created_at, updated_at';

/** The CHECK constraint on `segments.type` guarantees one of exactly two values. */
function toSegmentType(value: string): SegmentType {
  return value === 'break' ? 'break' : 'work';
}

function toDay(row: DayRow): Day {
  return {
    id: row.id,
    date: row.date,
    createdAt: row.created_at,
    endedAt: row.ended_at,
    targetMinutes: row.target_minutes,
  };
}

function toSegment(row: SegmentRow): Segment {
  return {
    id: row.id,
    dayId: row.day_id,
    type: toSegmentType(row.type),
    startedAt: row.started_at,
    endedAt: row.ended_at,
    note: row.note,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function dayFromJoin(row: DayJoinRow): Day {
  return {
    id: row.day_id,
    date: row.day_date,
    createdAt: row.day_created_at,
    endedAt: row.day_ended_at,
    targetMinutes: row.day_target_minutes,
  };
}

/**
 * `null` for a day that has no segments yet. A LEFT JOIN nulls every segment
 * column at once, so checking each NOT NULL column keeps the narrowing honest
 * without a non-null assertion.
 */
function segmentFromJoin(row: DayJoinRow): Segment | null {
  if (
    row.segment_id === null ||
    row.segment_day_id === null ||
    row.segment_type === null ||
    row.segment_started_at === null ||
    row.segment_created_at === null ||
    row.segment_updated_at === null
  ) {
    return null;
  }
  return {
    id: row.segment_id,
    dayId: row.segment_day_id,
    type: toSegmentType(row.segment_type),
    startedAt: row.segment_started_at,
    endedAt: row.segment_ended_at,
    note: row.segment_note,
    createdAt: row.segment_created_at,
    updatedAt: row.segment_updated_at,
  };
}

/* -------------------------------------------------------------------------- */
/* Statements                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Prepared once per connection and reused for the life of the app — preparing on
 * every call would dominate the cost of these queries.
 *
 * The bind tuples are part of the type, so a wrong argument count or a stray
 * object (which better-sqlite3 would reject at runtime) fails to compile instead.
 */
function prepareStatements(db: Database.Database) {
  return {
    dayByDate: db.prepare<[DateKey], DayRow>(`SELECT ${DAY_COLUMNS} FROM days WHERE date = ?`),

    dayById: db.prepare<[number], DayRow>(`SELECT ${DAY_COLUMNS} FROM days WHERE id = ?`),

    insertDay: db.prepare<[DateKey, EpochMs, number]>(
      'INSERT INTO days (date, created_at, ended_at, target_minutes) VALUES (?, ?, NULL, ?)',
    ),

    updateDayEnded: db.prepare<[EpochMs | null, number]>(
      'UPDATE days SET ended_at = ? WHERE id = ?',
    ),

    // Re-stamping a target is deliberately by id rather than by date: only the day in
    // progress is ever passed here, so a changed preference cannot rewrite history.
    updateDayTarget: db.prepare<[number, number]>('UPDATE days SET target_minutes = ? WHERE id = ?'),

    segmentsByDay: db.prepare<[number], SegmentRow>(
      `SELECT ${SEGMENT_COLUMNS} FROM segments WHERE day_id = ? ORDER BY started_at ASC, id ASC`,
    ),

    segmentById: db.prepare<[number], SegmentRow>(
      `SELECT ${SEGMENT_COLUMNS} FROM segments WHERE id = ?`,
    ),

    // Oldest first: if a bug ever left two rows open, resolving them oldest-first
    // drains the backlog instead of stranding an ancient one behind a newer one.
    openSegment: db.prepare<[], SegmentRow>(
      `SELECT ${SEGMENT_COLUMNS} FROM segments WHERE ended_at IS NULL ORDER BY started_at ASC, id ASC LIMIT 1`,
    ),

    insertSegment: db.prepare<
      [number, SegmentType, EpochMs, EpochMs | null, string | null, EpochMs, EpochMs]
    >(
      `INSERT INTO segments (day_id, type, started_at, ended_at, note, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ),

    // Every mutable column is written every time; the caller merges the patch over
    // the current row first, which keeps this a single reusable statement rather
    // than SQL assembled per call.
    updateSegment: db.prepare<
      [SegmentType, EpochMs, EpochMs | null, string | null, EpochMs, number]
    >(
      `UPDATE segments
          SET type = ?, started_at = ?, ended_at = ?, note = ?, updated_at = ?
        WHERE id = ?`,
    ),

    deleteSegment: db.prepare<[number]>('DELETE FROM segments WHERE id = ?'),

    // One pass over the range instead of a query per day: History opens on a full
    // month, which would otherwise be 31 round trips.
    range: db.prepare<[DateKey, DateKey], DayJoinRow>(
      `SELECT d.id             AS day_id,
              d.date           AS day_date,
              d.created_at     AS day_created_at,
              d.ended_at       AS day_ended_at,
              d.target_minutes AS day_target_minutes,
              s.id             AS segment_id,
              s.day_id         AS segment_day_id,
              s.type           AS segment_type,
              s.started_at     AS segment_started_at,
              s.ended_at       AS segment_ended_at,
              s.note           AS segment_note,
              s.created_at     AS segment_created_at,
              s.updated_at     AS segment_updated_at
         FROM days d
         LEFT JOIN segments s ON s.day_id = d.id
        WHERE d.date >= ? AND d.date <= ?
        ORDER BY d.date ASC, s.started_at ASC, s.id ASC`,
    ),

    appStateGet: db.prepare<[string], AppStateRow>('SELECT value FROM app_state WHERE key = ?'),

    appStateSet: db.prepare<[string, string]>(
      `INSERT INTO app_state (key, value) VALUES (?, ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    ),
  };
}

type Statements = ReturnType<typeof prepareStatements>;

/* -------------------------------------------------------------------------- */
/* Repository                                                                  */
/* -------------------------------------------------------------------------- */

export class Repository {
  private readonly db: Database.Database;
  private readonly stmt: Statements;

  constructor(db: Database.Database) {
    this.db = db;
    this.stmt = prepareStatements(db);
  }

  /* ---- days ---- */

  findDay(date: DateKey): Day | null {
    const row = this.stmt.dayByDate.get(date);
    return row === undefined ? null : toDay(row);
  }

  getOrCreateDay(date: DateKey, targetMinutes: number, now: EpochMs): Day {
    const existing = this.findDay(date);
    if (existing !== null) return existing;

    // The column has INTEGER affinity: a fractional target would be stored as REAL
    // and read back as a float, so it is normalised on the way in.
    const minutes = Math.round(targetMinutes);
    const result = this.stmt.insertDay.run(date, now, minutes);
    return {
      id: Number(result.lastInsertRowid),
      date,
      createdAt: now,
      endedAt: null,
      targetMinutes: minutes,
    };
  }

  /** `null` clears the flag — the user pressed Start again after End Day. */
  setDayEnded(dayId: number, endedAt: EpochMs | null): Day {
    this.stmt.updateDayEnded.run(endedAt, dayId);
    const row = this.stmt.dayById.get(dayId);
    if (row === undefined) throw new Error(`Day ${dayId} does not exist.`);
    return toDay(row);
  }

  /**
   * Re-stamps the target of an existing day. `getOrCreateDay` only ever stamps at
   * creation, so this is the one path by which a changed preference reaches a day that
   * has already started — and the caller is responsible for passing only that day.
   */
  setDayTarget(dayId: number, targetMinutes: number): Day {
    // Same normalisation as `getOrCreateDay`: the column has INTEGER affinity, so a
    // fractional target would be stored as REAL and read back as a float.
    this.stmt.updateDayTarget.run(Math.round(targetMinutes), dayId);
    const row = this.stmt.dayById.get(dayId);
    if (row === undefined) throw new Error(`Day ${dayId} does not exist.`);
    return toDay(row);
  }

  /* ---- reads ---- */

  listSegments(dayId: number): Segment[] {
    return this.stmt.segmentsByDay.all(dayId).map(toSegment);
  }

  getDayDetail(date: DateKey, now: EpochMs = Date.now()): DayDetail | null {
    const day = this.findDay(date);
    if (day === null) return null;
    const segments = this.listSegments(day.id);
    return { day, segments, totals: dayTotals(segments, date, now) };
  }

  /** Only days that exist in the table, ascending. Gaps are the caller's problem. */
  getRange(range: DateRange, now: EpochMs = Date.now()): DayDetail[] {
    const grouped: Array<{ day: Day; segments: Segment[] }> = [];
    let current: { day: Day; segments: Segment[] } | null = null;

    // Rows arrive grouped by day and ordered within it, so a single pass is enough.
    for (const row of this.stmt.range.all(range.from, range.to)) {
      if (current === null || current.day.id !== row.day_id) {
        current = { day: dayFromJoin(row), segments: [] };
        grouped.push(current);
      }
      const segment = segmentFromJoin(row);
      if (segment !== null) current.segments.push(segment);
    }

    return grouped.map(({ day, segments }) => ({
      day,
      segments,
      totals: dayTotals(segments, day.date, now),
    }));
  }

  getSegment(id: number): Segment | null {
    const row = this.stmt.segmentById.get(id);
    return row === undefined ? null : toSegment(row);
  }

  findOpenSegment(): Segment | null {
    const row = this.stmt.openSegment.get();
    return row === undefined ? null : toSegment(row);
  }

  /* ---- segment writes ---- */

  insertSegment(
    input: {
      dayId: number;
      type: SegmentType;
      startedAt: EpochMs;
      endedAt: EpochMs | null;
      note?: string | null;
    },
    now: EpochMs,
  ): Segment {
    const note = input.note ?? null;
    const result = this.stmt.insertSegment.run(
      input.dayId,
      input.type,
      input.startedAt,
      input.endedAt,
      note,
      now,
      now,
    );
    return {
      id: Number(result.lastInsertRowid),
      dayId: input.dayId,
      type: input.type,
      startedAt: input.startedAt,
      endedAt: input.endedAt,
      note,
      createdAt: now,
      updatedAt: now,
    };
  }

  updateSegmentFields(
    id: number,
    patch: {
      type?: SegmentType;
      startedAt?: EpochMs;
      endedAt?: EpochMs | null;
      note?: string | null;
    },
    now: EpochMs,
  ): Segment {
    const current = this.getSegment(id);
    if (current === null) throw new Error(`Segment ${id} does not exist.`);

    const next: Segment = {
      ...current,
      type: patch.type ?? current.type,
      startedAt: patch.startedAt ?? current.startedAt,
      // `??` would swallow an explicit `null`, and `null` is exactly how a segment
      // is reopened or a note is cleared.
      endedAt: patch.endedAt !== undefined ? patch.endedAt : current.endedAt,
      note: patch.note !== undefined ? patch.note : current.note,
      updatedAt: now,
    };

    this.stmt.updateSegment.run(next.type, next.startedAt, next.endedAt, next.note, now, id);
    return next;
  }

  deleteSegment(id: number): boolean {
    return this.stmt.deleteSegment.run(id).changes > 0;
  }

  /**
   * Close `id` at `endedAt`, splitting at every local midnight it crosses via
   * `splitAtMidnight`. The original row becomes the first piece; later pieces are
   * inserted against their own days (created on demand with `targetMinutes`).
   * Returns every resulting piece, ordered.
   */
  closeSegmentSplitting(
    id: number,
    endedAt: EpochMs,
    targetMinutes: number,
    now: EpochMs,
  ): Segment[] {
    return this.transaction(() => {
      const original = this.getSegment(id);
      if (original === null) throw new Error(`Segment ${id} does not exist.`);

      const [first, ...rest] = splitAtMidnight({
        type: original.type,
        startedAt: original.startedAt,
        endedAt,
      });

      // The first piece keeps the original row: its id is what the snapshot, the
      // idle prompt and any in-flight recovery are holding on to, so it has to
      // survive the close. Its `day_id` already matches the day it starts in.
      const pieces: Segment[] = [this.updateSegmentFields(id, { endedAt: first.endedAt }, now)];

      for (const piece of rest) {
        const day = this.getOrCreateDay(piece.date, targetMinutes, now);
        pieces.push(
          this.insertSegment(
            {
              dayId: day.id,
              type: piece.type,
              startedAt: piece.startedAt,
              endedAt: piece.endedAt,
              // The note described the whole span, so each half keeps it rather
              // than the tail silently losing it.
              note: original.note,
            },
            now,
          ),
        );
      }

      // `splitAtMidnight` yields contiguous ascending pieces, so this is ordered.
      return pieces;
    });
  }

  /* ---- app state ---- */

  getAppState(key: string): string | null {
    const row = this.stmt.appStateGet.get(key);
    return row === undefined ? null : row.value;
  }

  setAppState(key: string, value: string): void {
    this.stmt.appStateSet.run(key, value);
  }

  /* ---- lifecycle ---- */

  /**
   * Nesting is safe: better-sqlite3 promotes an inner transaction to a SAVEPOINT,
   * so a service may wrap a call that already wraps itself and only the outermost
   * commit hits the disk.
   */
  transaction<T>(fn: () => T): T {
    return this.db.transaction(fn)();
  }

  close(): void {
    this.db.close();
  }
}

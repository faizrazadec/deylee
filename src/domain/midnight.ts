/**
 * Midnight-crossover splitting.
 *
 * A segment that spans local midnight is stored as one piece per calendar day, so
 * every stored segment belongs to exactly one day and day totals need no special
 * cases. Splitting happens when a segment is closed, when the app notices the clock
 * has rolled over, and when a manual edit stretches a segment across a boundary.
 *
 * The boundaries come from `nextMidnightAfter`, which uses local calendar maths, so
 * 23-hour and 25-hour DST days split at the right instants.
 */

import { dateKeyOf, nextMidnightAfter } from '../shared/time';
import type { DateKey, EpochMs, SegmentType } from '../shared/types';

export interface SplittableSpan {
  type: SegmentType;
  startedAt: EpochMs;
  /** `null` means still open; an open span is never split until it closes. */
  endedAt: EpochMs | null;
}

/** One piece of a split span, tagged with the day it belongs to. */
export interface DaySpan {
  date: DateKey;
  type: SegmentType;
  startedAt: EpochMs;
  endedAt: EpochMs | null;
}

/** True when the span is closed and ends on a later local day than it started. */
export function crossesMidnight(span: SplittableSpan): boolean {
  if (span.endedAt === null) return false;
  if (span.endedAt <= span.startedAt) return false;
  return dateKeyOf(span.startedAt) !== dateKeyOf(span.endedAt);
}

/**
 * Split a span at every local midnight it crosses.
 *
 * - An open span is returned as a single open piece; it is split later, when closed.
 * - A zero-length or reversed span is returned unchanged as a single piece, so the
 *   caller's validation (not this function) decides whether to reject it.
 * - A piece that would end exactly at midnight does not produce an empty next piece.
 *
 * The returned pieces are contiguous and in ascending order: piece[n].endedAt
 * equals piece[n+1].startedAt.
 */
export function splitAtMidnight(span: SplittableSpan): DaySpan[] {
  if (span.endedAt === null) {
    return [
      {
        date: dateKeyOf(span.startedAt),
        type: span.type,
        startedAt: span.startedAt,
        endedAt: null,
      },
    ];
  }

  if (span.endedAt <= span.startedAt) {
    return [
      {
        date: dateKeyOf(span.startedAt),
        type: span.type,
        startedAt: span.startedAt,
        endedAt: span.endedAt,
      },
    ];
  }

  const pieces: DaySpan[] = [];
  let cursor = span.startedAt;

  while (cursor < span.endedAt) {
    const boundary = nextMidnightAfter(cursor);
    const pieceEnd = Math.min(boundary, span.endedAt);
    pieces.push({
      date: dateKeyOf(cursor),
      type: span.type,
      startedAt: cursor,
      endedAt: pieceEnd,
    });
    cursor = pieceEnd;
  }

  return pieces;
}

/**
 * Split an open span at midnight *as of* `now`, for the case where the app has been
 * left running past midnight: the piece up to the boundary is closed and a new open
 * piece begins at the boundary.
 *
 * Returns `null` when the span has not yet crossed a boundary, so the caller can
 * cheaply do nothing on the common path.
 */
export function splitOpenSpanAt(
  span: SplittableSpan,
  now: EpochMs,
): { closed: DaySpan[]; reopened: DaySpan } | null {
  if (span.endedAt !== null) return null;
  const boundary = nextMidnightAfter(span.startedAt);
  if (now < boundary) return null;

  const closedPieces = splitAtMidnight({
    type: span.type,
    startedAt: span.startedAt,
    endedAt: startOfCurrentDay(now),
  });

  return {
    closed: closedPieces,
    reopened: {
      date: dateKeyOf(now),
      type: span.type,
      startedAt: startOfCurrentDay(now),
      endedAt: null,
    },
  };
}

function startOfCurrentDay(now: EpochMs): EpochMs {
  // Local midnight at or before `now`.
  const d = new Date(now);
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0).getTime();
}

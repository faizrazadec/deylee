/**
 * Overlap validation. Segments must never overlap — not from the timer, and not
 * from a manual edit in the History window.
 *
 * Convention: intervals are half-open, `[startedAt, endedAt)`. Touching endpoints
 * (one segment ending exactly when the next begins) is *not* an overlap; that is
 * the normal shape of a pause/resume boundary.
 */

import { formatClock } from '../shared/time';
import type { EpochMs, MutationResult, Segment } from '../shared/types';

export interface Interval {
  startedAt: EpochMs;
  /** `null` = open-ended; it conflicts with everything after `startedAt`. */
  endedAt: EpochMs | null;
}

const OPEN_END = Number.POSITIVE_INFINITY;

function upperBound(interval: Interval): number {
  return interval.endedAt ?? OPEN_END;
}

/** True when the two intervals share any positive-length span of time. */
export function intervalsOverlap(a: Interval, b: Interval): boolean {
  return a.startedAt < upperBound(b) && b.startedAt < upperBound(a);
}

/**
 * The first stored segment that would conflict with `candidate`.
 *
 * `ignoreId` excludes the segment being edited from its own comparison.
 */
export function findOverlapping(
  candidate: Interval,
  existing: readonly Segment[],
  ignoreId?: number,
): Segment | null {
  for (const segment of existing) {
    if (ignoreId !== undefined && segment.id === ignoreId) continue;
    if (intervalsOverlap(candidate, segment)) return segment;
  }
  return null;
}

/**
 * Validate a proposed segment against the day's existing segments.
 *
 * Checks, in order: the range is well-formed, it is not zero-length, and it does
 * not overlap anything else.
 */
export function validateSegment(
  candidate: Interval,
  existing: readonly Segment[],
  ignoreId?: number,
): MutationResult<Interval> {
  if (!Number.isFinite(candidate.startedAt)) {
    return { ok: false, code: 'invalid-range', message: 'Start time is not a valid instant.' };
  }
  if (candidate.endedAt !== null) {
    if (!Number.isFinite(candidate.endedAt)) {
      return { ok: false, code: 'invalid-range', message: 'End time is not a valid instant.' };
    }
    if (candidate.endedAt < candidate.startedAt) {
      return { ok: false, code: 'invalid-range', message: 'End time is before the start time.' };
    }
    if (candidate.endedAt === candidate.startedAt) {
      return { ok: false, code: 'invalid-range', message: 'Start and end time are the same.' };
    }
  }

  const clash = findOverlapping(candidate, existing, ignoreId);
  if (clash !== null) {
    const clashEnd = clash.endedAt === null ? 'now' : formatClock(clash.endedAt);
    return {
      ok: false,
      code: 'overlap',
      message: `Overlaps the ${clash.type} segment from ${formatClock(clash.startedAt)} to ${clashEnd}.`,
    };
  }

  return { ok: true, value: candidate };
}

/**
 * At most one segment may be open at a time, app-wide. Used as a guard before
 * opening a new one and as an invariant check after recovery.
 */
export function findOpenSegments(segments: readonly Segment[]): Segment[] {
  return segments.filter((segment) => segment.endedAt === null);
}

/**
 * Duration and aggregation logic.
 *
 * Totals are *always* derived by summing segments. Nothing here reads or writes a
 * running counter, which is what makes the numbers survive crashes, restarts,
 * manual edits and machine sleep.
 */

import { startOfDay, endOfDay, startOfDayAt, MS_PER_HOUR, MS_PER_MINUTE } from '../shared/time';
import type {
  DateKey,
  DayTotals,
  EpochMs,
  LiveTotals,
  Segment,
  SegmentType,
  TimerSnapshot,
} from '../shared/types';

/** The minimum shape the duration maths needs. Lets tests use plain literals. */
export interface SpanLike {
  type: SegmentType;
  startedAt: EpochMs;
  endedAt: EpochMs | null;
}

/**
 * Duration of a single span. An open span (`endedAt === null`) is measured up to
 * `now`. Never negative — a reversed or future-started span contributes zero.
 */
export function spanDuration(span: SpanLike, now: EpochMs = Date.now()): number {
  const end = span.endedAt ?? now;
  return Math.max(0, end - span.startedAt);
}

/**
 * The portion of a span that falls inside the local calendar day `date`.
 *
 * Segments are normally split at midnight when they are closed, so this is a no-op
 * for stored data. It matters for the *open* segment, which can run past midnight
 * before the splitter has had a chance to act.
 */
export function spanDurationWithinDay(
  span: SpanLike,
  date: DateKey,
  now: EpochMs = Date.now(),
): number {
  const dayStart = startOfDay(date);
  const dayEnd = endOfDay(date);
  const start = Math.max(span.startedAt, dayStart);
  const end = Math.min(span.endedAt ?? now, dayEnd);
  return Math.max(0, end - start);
}

/** Sum the spans of one type, clipped to `date`. */
export function sumWithinDay(
  spans: readonly SpanLike[],
  type: SegmentType,
  date: DateKey,
  now: EpochMs = Date.now(),
): number {
  let total = 0;
  for (const span of spans) {
    if (span.type === type) total += spanDurationWithinDay(span, date, now);
  }
  return total;
}

/**
 * Full derived totals for a day.
 *
 * `firstStartAt` is the earliest segment start and `lastEndAt` the latest close;
 * `lastEndAt` is `null` while any segment is still open, because the day has not
 * finished yet.
 */
export function dayTotals(
  segments: readonly Segment[],
  date: DateKey,
  now: EpochMs = Date.now(),
): DayTotals {
  let workedMs = 0;
  let breakMs = 0;
  let firstStartAt: EpochMs | null = null;
  let lastEndAt: EpochMs | null = null;
  let hasOpenSegment = false;

  for (const segment of segments) {
    const duration = spanDurationWithinDay(segment, date, now);
    if (segment.type === 'work') workedMs += duration;
    else breakMs += duration;

    if (firstStartAt === null || segment.startedAt < firstStartAt) {
      firstStartAt = segment.startedAt;
    }
    if (segment.endedAt === null) {
      hasOpenSegment = true;
    } else if (lastEndAt === null || segment.endedAt > lastEndAt) {
      lastEndAt = segment.endedAt;
    }
  }

  return {
    workedMs,
    breakMs,
    firstStartAt,
    lastEndAt: hasOpenSegment ? null : lastEndAt,
    segmentCount: segments.length,
    hasOpenSegment,
  };
}

/**
 * Totals as of `now`, for the 1s render tick.
 *
 * The open segment's contribution is recomputed from timestamps every tick, and is
 * clamped to the start of the current local day so that a segment which ran across
 * midnight only credits today with today's share.
 */
export function liveTotals(snapshot: TimerSnapshot, now: EpochMs = Date.now()): LiveTotals {
  let workedMs = snapshot.closedWorkedMs;
  let breakMs = snapshot.closedBreakMs;

  const open = snapshot.openSegment;
  if (open !== null) {
    // Clamp to the current local midnight, not the snapshot's date, so the display
    // rolls over correctly if the app is left running past midnight.
    const dayStart = startOfDayAt(now);
    const elapsed = Math.max(0, now - Math.max(open.startedAt, dayStart));
    if (open.type === 'work') workedMs += elapsed;
    else breakMs += elapsed;
  }

  const targetMs = Math.max(0, snapshot.targetMinutes) * MS_PER_MINUTE;
  return {
    workedMs,
    breakMs,
    targetMs,
    targetProgress: targetMs > 0 ? workedMs / targetMs : 0,
    remainingToTargetMs: targetMs - workedMs,
  };
}

export function hoursToMinutes(hours: number): number {
  return Math.round(hours * 60);
}

export function minutesToMs(minutes: number): number {
  return minutes * MS_PER_MINUTE;
}

export function hoursToMs(hours: number): number {
  return hours * MS_PER_HOUR;
}

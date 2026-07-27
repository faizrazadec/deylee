/**
 * Tests for the duration/aggregation maths.
 *
 * Pinned to TZ=Europe/Berlin, so day-clipping is exercised against a 23-hour day
 * (2025-03-30) and a 25-hour day (2025-10-26) as well as ordinary ones. Instants are
 * always built with the local `Date(y, m - 1, d, ...)` constructor.
 */

import { describe, expect, it } from 'vitest';
import {
  dayTotals,
  hoursToMinutes,
  hoursToMs,
  liveTotals,
  minutesToMs,
  spanDuration,
  spanDurationWithinDay,
  sumWithinDay,
} from '@domain/duration';
import type { SpanLike } from '@domain/duration';
import type { Segment, SegmentType, TimerSnapshot } from '@shared/types';

const HOUR = 3_600_000;
const MINUTE = 60_000;

function local(y: number, m: number, d: number, h = 0, min = 0, s = 0, ms = 0): number {
  return new Date(y, m - 1, d, h, min, s, ms).getTime();
}

function span(type: SegmentType, startedAt: number, endedAt: number | null): SpanLike {
  return { type, startedAt, endedAt };
}

function segment(
  id: number,
  type: SegmentType,
  startedAt: number,
  endedAt: number | null,
): Segment {
  return {
    id,
    dayId: 1,
    type,
    startedAt,
    endedAt,
    note: null,
    createdAt: startedAt,
    updatedAt: endedAt ?? startedAt,
  };
}

function snapshot(patch: Partial<TimerSnapshot> = {}): TimerSnapshot {
  return {
    state: 'IDLE',
    date: '2025-08-04',
    dayId: 1,
    closedWorkedMs: 0,
    closedBreakMs: 0,
    openSegment: null,
    firstStartAt: null,
    lastEndAt: null,
    targetMinutes: 480,
    asOf: local(2025, 8, 4, 12, 0),
    ...patch,
  };
}

describe('spanDuration', () => {
  it('measures a closed span end-to-end', () => {
    expect(spanDuration(span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 11, 30)))).toBe(
      2 * HOUR + 30 * MINUTE,
    );
  });

  it('measures an open span up to now', () => {
    const started = local(2025, 8, 4, 9, 0);
    expect(spanDuration(span('work', started, null), local(2025, 8, 4, 10, 15))).toBe(
      HOUR + 15 * MINUTE,
    );
  });

  it('is zero for a reversed span', () => {
    expect(spanDuration(span('work', local(2025, 8, 4, 11, 0), local(2025, 8, 4, 9, 0)))).toBe(0);
  });

  it('is zero for a zero-length span', () => {
    const at = local(2025, 8, 4, 9, 0);
    expect(spanDuration(span('break', at, at))).toBe(0);
  });

  it('is zero for an open span that has not started yet', () => {
    const started = local(2025, 8, 4, 15, 0);
    expect(spanDuration(span('work', started, null), local(2025, 8, 4, 9, 0))).toBe(0);
  });

  it('measures real elapsed time across a DST transition, not wall-clock hours', () => {
    // 00:00 CET to 12:00 CEST on the 23-hour day is only 11 real hours.
    expect(spanDuration(span('work', local(2025, 3, 30, 0, 0), local(2025, 3, 30, 12, 0)))).toBe(
      11 * HOUR,
    );
    // 00:00 CEST to 12:00 CET on the 25-hour day is 13 real hours.
    expect(spanDuration(span('work', local(2025, 10, 26, 0, 0), local(2025, 10, 26, 12, 0)))).toBe(
      13 * HOUR,
    );
  });

  it('defaults `now` to the current instant for an open span', () => {
    const measured = spanDuration(span('work', Date.now() - 5 * MINUTE, null));
    expect(measured).toBeGreaterThanOrEqual(5 * MINUTE);
    expect(measured).toBeLessThan(6 * MINUTE);
  });
});

describe('spanDurationWithinDay', () => {
  const DAY = '2025-08-04';

  it('returns the whole span when it sits inside the day', () => {
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 17, 0)), DAY),
    ).toBe(8 * HOUR);
  });

  it('clips a span that starts before the day', () => {
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 3, 22, 0), local(2025, 8, 4, 1, 30)), DAY),
    ).toBe(HOUR + 30 * MINUTE);
  });

  it('clips a span that ends after the day', () => {
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 4, 22, 0), local(2025, 8, 5, 1, 30)), DAY),
    ).toBe(2 * HOUR);
  });

  it('clips a span that starts before and ends after the day, to the whole day', () => {
    const wide = span('work', local(2025, 8, 3, 22, 0), local(2025, 8, 5, 3, 0));
    expect(spanDurationWithinDay(wide, DAY)).toBe(24 * HOUR);
  });

  it('clips a whole-day overlap to 23 hours on the spring-forward day', () => {
    const wide = span('work', local(2025, 3, 29, 22, 0), local(2025, 3, 31, 3, 0));
    expect(spanDurationWithinDay(wide, '2025-03-30')).toBe(23 * HOUR);
  });

  it('clips a whole-day overlap to 25 hours on the fall-back day', () => {
    const wide = span('work', local(2025, 10, 25, 22, 0), local(2025, 10, 27, 3, 0));
    expect(spanDurationWithinDay(wide, '2025-10-26')).toBe(25 * HOUR);
  });

  it('is zero when the span does not touch the day at all', () => {
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 1, 9, 0), local(2025, 8, 1, 17, 0)), DAY),
    ).toBe(0);
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 6, 9, 0), local(2025, 8, 6, 17, 0)), DAY),
    ).toBe(0);
  });

  it('is zero for spans that merely touch a day boundary', () => {
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 3, 22, 0), local(2025, 8, 4, 0, 0)), DAY),
    ).toBe(0);
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 5, 0, 0), local(2025, 8, 5, 2, 0)), DAY),
    ).toBe(0);
  });

  it('is zero for a reversed span', () => {
    expect(
      spanDurationWithinDay(span('work', local(2025, 8, 4, 17, 0), local(2025, 8, 4, 9, 0)), DAY),
    ).toBe(0);
  });

  it('measures an open span up to now', () => {
    const open = span('work', local(2025, 8, 4, 9, 0), null);
    expect(spanDurationWithinDay(open, DAY, local(2025, 8, 4, 12, 30))).toBe(3 * HOUR + 30 * MINUTE);
  });

  it('credits today only with today for an open span that began yesterday', () => {
    const open = span('work', local(2025, 8, 3, 23, 0), null);
    expect(spanDurationWithinDay(open, DAY, local(2025, 8, 4, 2, 30))).toBe(2 * HOUR + 30 * MINUTE);
    expect(spanDurationWithinDay(open, '2025-08-03', local(2025, 8, 4, 2, 30))).toBe(HOUR);
  });

  it('stops an open span at the end of the day once now has moved past it', () => {
    const open = span('work', local(2025, 8, 4, 22, 0), null);
    expect(spanDurationWithinDay(open, DAY, local(2025, 8, 5, 6, 0))).toBe(2 * HOUR);
  });
});

describe('sumWithinDay', () => {
  const DAY = '2025-08-04';
  const spans: SpanLike[] = [
    span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 12, 0)),
    span('break', local(2025, 8, 4, 12, 0), local(2025, 8, 4, 12, 45)),
    span('work', local(2025, 8, 4, 12, 45), local(2025, 8, 4, 17, 0)),
    span('break', local(2025, 8, 4, 17, 0), local(2025, 8, 4, 17, 15)),
  ];

  it('sums only the requested type', () => {
    expect(sumWithinDay(spans, 'work', DAY)).toBe(7 * HOUR + 15 * MINUTE);
    expect(sumWithinDay(spans, 'break', DAY)).toBe(HOUR);
  });

  it('is zero for an empty list', () => {
    expect(sumWithinDay([], 'work', DAY)).toBe(0);
  });

  it('is zero when nothing matches the type', () => {
    expect(sumWithinDay([spans[0], spans[2]], 'break', DAY)).toBe(0);
  });

  it('clips each span to the day before summing', () => {
    const straddling: SpanLike[] = [
      span('work', local(2025, 8, 3, 23, 0), local(2025, 8, 4, 1, 0)),
      span('work', local(2025, 8, 4, 23, 0), local(2025, 8, 5, 2, 0)),
    ];
    expect(sumWithinDay(straddling, 'work', DAY)).toBe(2 * HOUR);
    expect(sumWithinDay(straddling, 'work', '2025-08-03')).toBe(HOUR);
    expect(sumWithinDay(straddling, 'work', '2025-08-05')).toBe(2 * HOUR);
  });

  it('includes the open span, measured to now', () => {
    const withOpen: SpanLike[] = [
      span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 12, 0)),
      span('work', local(2025, 8, 4, 13, 0), null),
    ];
    expect(sumWithinDay(withOpen, 'work', DAY, local(2025, 8, 4, 14, 30))).toBe(
      4 * HOUR + 30 * MINUTE,
    );
  });
});

describe('dayTotals', () => {
  const DAY = '2025-08-04';

  it('is all zeros and nulls for a day with no segments', () => {
    expect(dayTotals([], DAY, local(2025, 8, 4, 12, 0))).toEqual({
      workedMs: 0,
      breakMs: 0,
      firstStartAt: null,
      lastEndAt: null,
      segmentCount: 0,
      hasOpenSegment: false,
    });
  });

  it('derives worked, break, first start, last end and the segment count', () => {
    const segments = [
      segment(1, 'work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 12, 0)),
      segment(2, 'break', local(2025, 8, 4, 12, 0), local(2025, 8, 4, 12, 45)),
      segment(3, 'work', local(2025, 8, 4, 12, 45), local(2025, 8, 4, 17, 30)),
    ];

    expect(dayTotals(segments, DAY, local(2025, 8, 4, 18, 0))).toEqual({
      workedMs: 7 * HOUR + 45 * MINUTE,
      breakMs: 45 * MINUTE,
      firstStartAt: local(2025, 8, 4, 9, 0),
      lastEndAt: local(2025, 8, 4, 17, 30),
      segmentCount: 3,
      hasOpenSegment: false,
    });
  });

  it('takes the earliest start and latest end regardless of storage order', () => {
    const segments = [
      segment(3, 'work', local(2025, 8, 4, 14, 0), local(2025, 8, 4, 17, 30)),
      segment(1, 'work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 12, 0)),
      segment(2, 'break', local(2025, 8, 4, 12, 0), local(2025, 8, 4, 14, 0)),
    ];
    const totals = dayTotals(segments, DAY, local(2025, 8, 4, 18, 0));
    expect(totals.firstStartAt).toBe(local(2025, 8, 4, 9, 0));
    expect(totals.lastEndAt).toBe(local(2025, 8, 4, 17, 30));
  });

  it('reports lastEndAt as null while a segment is still open', () => {
    const segments = [
      segment(1, 'work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 12, 0)),
      segment(2, 'break', local(2025, 8, 4, 12, 0), local(2025, 8, 4, 12, 30)),
      segment(3, 'work', local(2025, 8, 4, 12, 30), null),
    ];
    const totals = dayTotals(segments, DAY, local(2025, 8, 4, 15, 0));

    expect(totals.hasOpenSegment).toBe(true);
    expect(totals.lastEndAt).toBeNull();
    expect(totals.firstStartAt).toBe(local(2025, 8, 4, 9, 0));
    expect(totals.workedMs).toBe(5 * HOUR + 30 * MINUTE);
    expect(totals.breakMs).toBe(30 * MINUTE);
    expect(totals.segmentCount).toBe(3);
  });

  it('counts an open break into the break bucket', () => {
    const segments = [segment(1, 'break', local(2025, 8, 4, 12, 0), null)];
    const totals = dayTotals(segments, DAY, local(2025, 8, 4, 12, 20));
    expect(totals.breakMs).toBe(20 * MINUTE);
    expect(totals.workedMs).toBe(0);
    expect(totals.hasOpenSegment).toBe(true);
  });

  it('clips a segment that leaks past midnight to the day being totalled', () => {
    const segments = [segment(1, 'work', local(2025, 8, 4, 22, 0), local(2025, 8, 5, 2, 0))];
    expect(dayTotals(segments, DAY, local(2025, 8, 5, 9, 0)).workedMs).toBe(2 * HOUR);
    expect(dayTotals(segments, '2025-08-05', local(2025, 8, 5, 9, 0)).workedMs).toBe(2 * HOUR);
  });

  it('clips against the 23h and 25h days', () => {
    const short = [segment(1, 'work', local(2025, 3, 30, 0, 0), local(2025, 3, 31, 0, 0))];
    expect(dayTotals(short, '2025-03-30', local(2025, 3, 31, 9, 0)).workedMs).toBe(23 * HOUR);

    const long = [segment(1, 'work', local(2025, 10, 26, 0, 0), local(2025, 10, 27, 0, 0))];
    expect(dayTotals(long, '2025-10-26', local(2025, 10, 27, 9, 0)).workedMs).toBe(25 * HOUR);
  });
});

describe('liveTotals', () => {
  const TARGET_MS = 480 * MINUTE;

  it('returns the closed totals when nothing is open', () => {
    const live = liveTotals(
      snapshot({ closedWorkedMs: 4 * HOUR, closedBreakMs: 30 * MINUTE }),
      local(2025, 8, 4, 14, 0),
    );

    expect(live.workedMs).toBe(4 * HOUR);
    expect(live.breakMs).toBe(30 * MINUTE);
    expect(live.targetMs).toBe(TARGET_MS);
    expect(live.targetProgress).toBeCloseTo(0.5, 10);
    expect(live.remainingToTargetMs).toBe(4 * HOUR);
  });

  it('adds an open work segment to the worked bucket only', () => {
    const live = liveTotals(
      snapshot({
        state: 'RUNNING',
        closedWorkedMs: 4 * HOUR,
        closedBreakMs: 30 * MINUTE,
        openSegment: segment(9, 'work', local(2025, 8, 4, 13, 0), null),
      }),
      local(2025, 8, 4, 14, 30),
    );

    expect(live.workedMs).toBe(5 * HOUR + 30 * MINUTE);
    expect(live.breakMs).toBe(30 * MINUTE);
    expect(live.remainingToTargetMs).toBe(2 * HOUR + 30 * MINUTE);
  });

  it('adds an open break segment to the break bucket only', () => {
    const live = liveTotals(
      snapshot({
        state: 'PAUSED',
        closedWorkedMs: 4 * HOUR,
        closedBreakMs: 30 * MINUTE,
        openSegment: segment(9, 'break', local(2025, 8, 4, 13, 0), null),
      }),
      local(2025, 8, 4, 13, 45),
    );

    expect(live.workedMs).toBe(4 * HOUR);
    expect(live.breakMs).toBe(HOUR + 15 * MINUTE);
  });

  it('clamps an open segment that began yesterday to today local midnight', () => {
    const live = liveTotals(
      snapshot({
        state: 'RUNNING',
        openSegment: segment(9, 'work', local(2025, 8, 3, 22, 0), null),
      }),
      local(2025, 8, 4, 2, 30),
    );

    expect(live.workedMs).toBe(2 * HOUR + 30 * MINUTE);
  });

  it('clamps to the current local midnight even when it is 25 hours from the previous one', () => {
    const live = liveTotals(
      snapshot({
        state: 'RUNNING',
        date: '2025-10-26',
        openSegment: segment(9, 'work', local(2025, 10, 25, 23, 0), null),
      }),
      local(2025, 10, 26, 1, 0),
    );

    expect(live.workedMs).toBe(HOUR);
  });

  it('contributes nothing for an open segment that has not started yet', () => {
    const live = liveTotals(
      snapshot({
        state: 'RUNNING',
        closedWorkedMs: HOUR,
        openSegment: segment(9, 'work', local(2025, 8, 4, 16, 0), null),
      }),
      local(2025, 8, 4, 15, 0),
    );

    expect(live.workedMs).toBe(HOUR);
  });

  it('lets progress exceed 1 and remaining go negative past the target', () => {
    const live = liveTotals(
      snapshot({ closedWorkedMs: 9 * HOUR, targetMinutes: 480 }),
      local(2025, 8, 4, 19, 0),
    );

    expect(live.targetProgress).toBeCloseTo(1.125, 10);
    expect(live.remainingToTargetMs).toBe(-HOUR);
  });

  it('reports zero progress for a zero target instead of dividing by zero', () => {
    const live = liveTotals(
      snapshot({ closedWorkedMs: 3 * HOUR, targetMinutes: 0 }),
      local(2025, 8, 4, 12, 0),
    );

    expect(live.targetMs).toBe(0);
    expect(live.targetProgress).toBe(0);
    expect(live.remainingToTargetMs).toBe(-3 * HOUR);
  });

  it('treats a negative target as zero', () => {
    const live = liveTotals(
      snapshot({ closedWorkedMs: HOUR, targetMinutes: -60 }),
      local(2025, 8, 4, 12, 0),
    );

    expect(live.targetMs).toBe(0);
    expect(live.targetProgress).toBe(0);
  });
});

describe('unit conversions', () => {
  it('rounds hours to whole minutes', () => {
    expect(hoursToMinutes(8)).toBe(480);
    expect(hoursToMinutes(7.5)).toBe(450);
    expect(hoursToMinutes(0)).toBe(0);
    expect(hoursToMinutes(0.26)).toBe(16);
  });

  it('converts minutes and hours to milliseconds', () => {
    expect(minutesToMs(90)).toBe(90 * MINUTE);
    expect(minutesToMs(0)).toBe(0);
    expect(hoursToMs(2.5)).toBe(2.5 * HOUR);
  });
});

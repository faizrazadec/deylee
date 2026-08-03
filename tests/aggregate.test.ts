/**
 * Tests for the History range roll-ups.
 *
 * The one rule that is easy to get wrong and expensive to get wrong is the daily
 * average: it divides by *active* days, so a month of weekends must not drag it down.
 */

import { describe, expect, it } from 'vitest';
import { densifyRange, monthRange, subRange, summariseRange, weekRange } from '@domain/aggregate';
import type { DateKey, DayDetail, Segment } from '@shared/types';

const HOUR = 3_600_000;
const MINUTE = 60_000;

let nextSegmentId = 1;

function instantOn(date: DateKey, hour: number): number {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(y, m - 1, d, hour, 0, 0, 0).getTime();
}

interface DetailSpec {
  targetMinutes?: number;
  workedMs?: number;
  breakMs?: number;
}

/**
 * A realistic `DayDetail`: the segments and the totals agree, so a reader can see
 * where each number in the expectations comes from.
 */
function detail(date: DateKey, spec: DetailSpec = {}): DayDetail {
  const { targetMinutes = 480, workedMs = 0, breakMs = 0 } = spec;
  const segments: Segment[] = [];
  let cursor = instantOn(date, 9);

  const push = (type: 'work' | 'break', duration: number): void => {
    const startedAt = cursor;
    const endedAt = startedAt + duration;
    segments.push({
      id: nextSegmentId++,
      dayId: 1,
      type,
      startedAt,
      endedAt,
      note: null,
      createdAt: startedAt,
      updatedAt: endedAt,
    });
    cursor = endedAt;
  };

  if (workedMs > 0) push('work', workedMs);
  if (breakMs > 0) push('break', breakMs);

  const last = segments[segments.length - 1];
  return {
    day: {
      id: 1,
      date,
      createdAt: instantOn(date, 9),
      endedAt: null,
      targetMinutes,
    },
    segments,
    totals: {
      workedMs,
      breakMs,
      firstStartAt: segments.length > 0 ? segments[0].startedAt : null,
      lastEndAt: segments.length > 0 ? last.endedAt : null,
      segmentCount: segments.length,
      hasOpenSegment: false,
    },
  };
}

describe('summariseRange', () => {
  const range = { from: '2025-08-04', to: '2025-08-10' };
  const days = [
    detail('2025-08-04', { workedMs: 8 * HOUR, breakMs: 45 * MINUTE }),
    detail('2025-08-05', { workedMs: 6 * HOUR, breakMs: 30 * MINUTE }),
    detail('2025-08-06', { workedMs: 9 * HOUR, breakMs: 60 * MINUTE }),
    detail('2025-08-07', { breakMs: 20 * MINUTE }),
  ];

  it('sums worked and break time across the range', () => {
    const summary = summariseRange(range, days);
    expect(summary.totalWorkedMs).toBe(23 * HOUR);
    expect(summary.totalBreakMs).toBe(2 * HOUR + 35 * MINUTE);
  });

  it('echoes the range back and copies the day list', () => {
    const summary = summariseRange(range, days);
    expect(summary.range).toBe(range);
    expect(summary.days).toEqual(days);
    expect(summary.days).not.toBe(days);
  });

  it('counts only days with recorded work as active', () => {
    // 2025-08-07 has a break but no work, so it is not an active day.
    expect(summariseRange(range, days).activeDayCount).toBe(3);
  });

  it('divides the average by active days, not by calendar days in the range', () => {
    const summary = summariseRange(range, days);
    // 23h over 3 active days — dividing by the 7 calendar days would give 3h17m.
    expect(summary.averageWorkedMsPerActiveDay).toBeCloseTo((23 * HOUR) / 3, 6);
    expect(summary.averageWorkedMsPerActiveDay).not.toBeCloseTo((23 * HOUR) / 7, 6);
  });

  it('reports a zero average when nothing was worked', () => {
    const idle = summariseRange(range, [
      detail('2025-08-04', { breakMs: 30 * MINUTE }),
      detail('2025-08-05'),
    ]);

    expect(idle.activeDayCount).toBe(0);
    expect(idle.averageWorkedMsPerActiveDay).toBe(0);
    expect(idle.totalWorkedMs).toBe(0);
    expect(idle.totalBreakMs).toBe(30 * MINUTE);
    expect(idle.targetMetCount).toBe(0);
  });

  it('is all zeros for an empty range', () => {
    const empty = summariseRange(range, []);
    expect(empty.days).toEqual([]);
    expect(empty.totalWorkedMs).toBe(0);
    expect(empty.totalBreakMs).toBe(0);
    expect(empty.activeDayCount).toBe(0);
    expect(empty.averageWorkedMsPerActiveDay).toBe(0);
    expect(empty.targetMetCount).toBe(0);
  });

  it('counts a day that meets its target exactly', () => {
    // 08-04 hits 8h against a 480-minute target, 08-06 exceeds it, 08-05 falls short.
    expect(summariseRange(range, days).targetMetCount).toBe(2);
  });

  it('compares each day against its own stored target', () => {
    const mixed = [
      detail('2025-08-04', { workedMs: 4 * HOUR, targetMinutes: 240 }),
      detail('2025-08-05', { workedMs: 4 * HOUR, targetMinutes: 480 }),
    ];
    expect(summariseRange(range, mixed).targetMetCount).toBe(1);
  });

  it('never counts a day with a zero target as met', () => {
    const untargeted = [
      detail('2025-08-04', { workedMs: 8 * HOUR, targetMinutes: 0 }),
      detail('2025-08-05', { targetMinutes: 0 }),
    ];
    const summary = summariseRange(range, untargeted);

    expect(summary.targetMetCount).toBe(0);
    expect(summary.activeDayCount).toBe(1);
  });
});

describe('densifyRange', () => {
  it('produces one entry per day of the range, in order', () => {
    const range = { from: '2025-08-04', to: '2025-08-10' };
    const dense = densifyRange(range, [
      detail('2025-08-05', { workedMs: 6 * HOUR }),
      detail('2025-08-08', { workedMs: 7 * HOUR }),
    ]);

    expect([...dense.keys()]).toEqual([
      '2025-08-04',
      '2025-08-05',
      '2025-08-06',
      '2025-08-07',
      '2025-08-08',
      '2025-08-09',
      '2025-08-10',
    ]);
    expect(dense.get('2025-08-04')).toBeNull();
    expect(dense.get('2025-08-05')?.totals.workedMs).toBe(6 * HOUR);
    expect(dense.get('2025-08-06')).toBeNull();
    expect(dense.get('2025-08-07')).toBeNull();
    expect(dense.get('2025-08-08')?.totals.workedMs).toBe(7 * HOUR);
    expect(dense.get('2025-08-10')).toBeNull();
  });

  it('fills the whole range with nulls when there is no data', () => {
    const dense = densifyRange({ from: '2025-08-04', to: '2025-08-06' }, []);
    expect(dense.size).toBe(3);
    expect([...dense.values()]).toEqual([null, null, null]);
  });

  it('drops days that fall outside the range', () => {
    const dense = densifyRange({ from: '2025-08-04', to: '2025-08-05' }, [
      detail('2025-08-01', { workedMs: HOUR }),
      detail('2025-08-05', { workedMs: 2 * HOUR }),
      detail('2025-08-09', { workedMs: 3 * HOUR }),
    ]);

    expect(dense.size).toBe(2);
    expect(dense.has('2025-08-01')).toBe(false);
    expect(dense.has('2025-08-09')).toBe(false);
    expect(dense.get('2025-08-05')?.totals.workedMs).toBe(2 * HOUR);
  });

  it('handles a single-day range', () => {
    const only = detail('2025-08-04', { workedMs: HOUR });
    const dense = densifyRange({ from: '2025-08-04', to: '2025-08-04' }, [only]);
    expect(dense.size).toBe(1);
    expect(dense.get('2025-08-04')).toBe(only);
  });

  it('is empty for a reversed range', () => {
    const dense = densifyRange({ from: '2025-08-10', to: '2025-08-04' }, [
      detail('2025-08-05', { workedMs: HOUR }),
    ]);
    expect(dense.size).toBe(0);
  });

  it('emits every day of a DST week exactly once', () => {
    const dense = densifyRange({ from: '2025-03-29', to: '2025-03-31' }, [
      detail('2025-03-30', { workedMs: 3 * HOUR }),
    ]);

    expect([...dense.keys()]).toEqual(['2025-03-29', '2025-03-30', '2025-03-31']);
    expect(dense.get('2025-03-30')?.totals.workedMs).toBe(3 * HOUR);
  });
});

describe('weekRange', () => {
  // 2025-08-03 Sun, 2025-08-04 Mon, 2025-08-06 Wed, 2025-08-09 Sat, 2025-08-10 Sun.
  it('runs Monday to Sunday when weeks start on Monday', () => {
    expect(weekRange('2025-08-06', 1)).toEqual({ from: '2025-08-04', to: '2025-08-10' });
  });

  it('runs Sunday to Saturday when weeks start on Sunday', () => {
    expect(weekRange('2025-08-06', 0)).toEqual({ from: '2025-08-03', to: '2025-08-09' });
  });

  it('places a Sunday at the end of a Monday week and the start of a Sunday week', () => {
    expect(weekRange('2025-08-10', 1)).toEqual({ from: '2025-08-04', to: '2025-08-10' });
    expect(weekRange('2025-08-10', 0)).toEqual({ from: '2025-08-10', to: '2025-08-16' });
  });

  it('spans month boundaries', () => {
    expect(weekRange('2025-08-01', 1)).toEqual({ from: '2025-07-28', to: '2025-08-03' });
  });

  it('stays seven days long across a DST transition', () => {
    expect(weekRange('2025-03-30', 1)).toEqual({ from: '2025-03-24', to: '2025-03-30' });
    expect(weekRange('2025-10-26', 1)).toEqual({ from: '2025-10-20', to: '2025-10-26' });
  });
});

describe('monthRange', () => {
  it('brackets an ordinary month', () => {
    expect(monthRange('2025-08-15')).toEqual({ from: '2025-08-01', to: '2025-08-31' });
    expect(monthRange('2025-08-01')).toEqual({ from: '2025-08-01', to: '2025-08-31' });
    expect(monthRange('2025-08-31')).toEqual({ from: '2025-08-01', to: '2025-08-31' });
  });

  it('gives a leap-year February 29 days', () => {
    expect(monthRange('2024-02-10')).toEqual({ from: '2024-02-01', to: '2024-02-29' });
    expect(monthRange('2024-02-29')).toEqual({ from: '2024-02-01', to: '2024-02-29' });
  });

  it('gives a non-leap February 28 days', () => {
    expect(monthRange('2025-02-10')).toEqual({ from: '2025-02-01', to: '2025-02-28' });
  });

  it('handles 30-day months, December and the DST months', () => {
    expect(monthRange('2025-04-15')).toEqual({ from: '2025-04-01', to: '2025-04-30' });
    expect(monthRange('2025-12-31')).toEqual({ from: '2025-12-01', to: '2025-12-31' });
    expect(monthRange('2025-03-30')).toEqual({ from: '2025-03-01', to: '2025-03-31' });
    expect(monthRange('2025-10-26')).toEqual({ from: '2025-10-01', to: '2025-10-31' });
  });
});

describe('subRange', () => {
  const loaded = [
    detail('2025-08-03', { workedMs: 2 * HOUR }),
    detail('2025-08-04', { workedMs: 8 * HOUR }),
    detail('2025-08-06', { workedMs: 9 * HOUR }),
    detail('2025-08-11', { workedMs: 5 * HOUR }),
  ];

  it('summarises only the days inside the sub-range, inclusive of both ends', () => {
    const summary = subRange(loaded, weekRange('2025-08-06', 1));

    expect(summary.range).toEqual({ from: '2025-08-04', to: '2025-08-10' });
    expect(summary.days.map((d) => d.day.date)).toEqual(['2025-08-04', '2025-08-06']);
    expect(summary.totalWorkedMs).toBe(17 * HOUR);
    expect(summary.activeDayCount).toBe(2);
    expect(summary.targetMetCount).toBe(2);
  });

  it('is empty when nothing loaded falls inside the sub-range', () => {
    const summary = subRange(loaded, { from: '2025-09-01', to: '2025-09-30' });
    expect(summary.days).toEqual([]);
    expect(summary.totalWorkedMs).toBe(0);
    expect(summary.averageWorkedMsPerActiveDay).toBe(0);
  });
});

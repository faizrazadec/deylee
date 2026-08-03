/**
 * Tests for the shared local-calendar helpers.
 *
 * The suite is pinned to TZ=Europe/Berlin, where 2025-03-30 is a 23-hour day
 * (02:00-03:00 never happens) and 2025-10-26 is a 25-hour day (02:00-03:00 happens
 * twice). Expected instants are built with the local `Date(y, m - 1, d, ...)`
 * constructor rather than by adding fixed offsets — adding offsets is exactly the
 * mistake these helpers exist to prevent, so it must never be how they are checked.
 */

import { describe, expect, it } from 'vitest';
import {
  MS_PER_HOUR,
  MS_PER_MINUTE,
  MS_PER_SECOND,
  addDays,
  dateKeyOf,
  daysBetween,
  eachDay,
  endOfDay,
  endOfMonth,
  endOfWeek,
  formatClock,
  formatClockSeconds,
  formatCompact,
  formatDateLong,
  formatHM,
  formatHMS,
  fromTimeInputValue,
  isDateKey,
  nextMidnightAfter,
  startOfDay,
  startOfDayAt,
  startOfMonth,
  startOfWeek,
  todayKey,
  toTimeInputValue,
} from '@shared/time';

const HOUR = 3_600_000;
const MINUTE = 60_000;
const SECOND = 1_000;

function local(y: number, m: number, d: number, h = 0, min = 0, s = 0, ms = 0): number {
  return new Date(y, m - 1, d, h, min, s, ms).getTime();
}

/** Narrows `EpochMs | null` so a round-trip assertion can use the number directly. */
function requireInstant(value: number | null): number {
  if (value === null) throw new Error('expected a parsable time input');
  return value;
}

describe('constants', () => {
  it('are the plain millisecond factors', () => {
    expect(MS_PER_SECOND).toBe(1_000);
    expect(MS_PER_MINUTE).toBe(60_000);
    expect(MS_PER_HOUR).toBe(3_600_000);
  });
});

describe('dateKeyOf', () => {
  it('zero-pads month and day', () => {
    expect(dateKeyOf(local(2025, 8, 4, 14, 37))).toBe('2025-08-04');
    expect(dateKeyOf(local(2025, 1, 1, 0, 0))).toBe('2025-01-01');
    expect(dateKeyOf(local(2025, 12, 31, 23, 59, 59, 999))).toBe('2025-12-31');
  });

  it('uses the local day, so the last millisecond of a day still belongs to it', () => {
    expect(dateKeyOf(local(2025, 8, 4, 23, 59, 59, 999))).toBe('2025-08-04');
    expect(dateKeyOf(local(2025, 8, 5, 0, 0, 0, 0))).toBe('2025-08-05');
  });

  it('is stable across both DST transitions', () => {
    expect(dateKeyOf(local(2025, 3, 30, 1, 59))).toBe('2025-03-30');
    expect(dateKeyOf(local(2025, 3, 30, 3, 0))).toBe('2025-03-30');
    // Both occurrences of the repeated hour belong to 2025-10-26.
    expect(dateKeyOf(local(2025, 10, 26, 2, 30))).toBe('2025-10-26');
    expect(dateKeyOf(local(2025, 10, 26, 2, 30) + HOUR)).toBe('2025-10-26');
  });
});

describe('isDateKey', () => {
  it('accepts well-formed, real calendar dates', () => {
    expect(isDateKey('2025-08-04')).toBe(true);
    expect(isDateKey('2024-02-29')).toBe(true);
    expect(isDateKey('1999-12-31')).toBe(true);
  });

  it('rejects malformed shapes', () => {
    expect(isDateKey('')).toBe(false);
    expect(isDateKey('2025-8-04')).toBe(false);
    expect(isDateKey('20250804')).toBe(false);
    expect(isDateKey('2025-08-04T00:00:00Z')).toBe(false);
    expect(isDateKey('2025/08/04')).toBe(false);
  });

  it('rejects dates that do not exist', () => {
    expect(isDateKey('2025-13-01')).toBe(false);
    expect(isDateKey('2025-00-10')).toBe(false);
    expect(isDateKey('2025-08-00')).toBe(false);
    expect(isDateKey('2025-08-32')).toBe(false);
    expect(isDateKey('2025-02-29')).toBe(false);
    expect(isDateKey('2025-02-30')).toBe(false);
    expect(isDateKey('2025-04-31')).toBe(false);
  });
});

describe('startOfDay / endOfDay', () => {
  it('returns local midnight and the next local midnight', () => {
    expect(startOfDay('2025-08-04')).toBe(local(2025, 8, 4));
    expect(endOfDay('2025-08-04')).toBe(local(2025, 8, 5));
    expect(endOfDay('2025-08-04') - startOfDay('2025-08-04')).toBe(24 * HOUR);
  });

  it('measures the spring-forward day as 23 hours', () => {
    expect(startOfDay('2025-03-30')).toBe(local(2025, 3, 30));
    expect(endOfDay('2025-03-30')).toBe(local(2025, 3, 31));
    expect(endOfDay('2025-03-30') - startOfDay('2025-03-30')).toBe(23 * HOUR);
  });

  it('skips 02:00 on the spring-forward day', () => {
    // Two hours after local midnight the wall clock already reads 03:00.
    expect(new Date(startOfDay('2025-03-30') + 2 * HOUR).getHours()).toBe(3);
  });

  it('measures the fall-back day as 25 hours', () => {
    expect(startOfDay('2025-10-26')).toBe(local(2025, 10, 26));
    expect(endOfDay('2025-10-26')).toBe(local(2025, 10, 27));
    expect(endOfDay('2025-10-26') - startOfDay('2025-10-26')).toBe(25 * HOUR);
  });

  it('repeats 02:00 on the fall-back day', () => {
    const base = startOfDay('2025-10-26');
    expect(new Date(base + 2 * HOUR).getHours()).toBe(2);
    expect(new Date(base + 3 * HOUR).getHours()).toBe(2);
  });

  it('rolls over month and year boundaries', () => {
    expect(endOfDay('2025-08-31')).toBe(local(2025, 9, 1));
    expect(endOfDay('2024-12-31')).toBe(local(2025, 1, 1));
    expect(endOfDay('2024-02-28')).toBe(local(2024, 2, 29));
  });
});

describe('startOfDayAt / nextMidnightAfter', () => {
  it('snaps an arbitrary instant to its own local day boundaries', () => {
    const ts = local(2025, 8, 4, 14, 37, 12, 345);
    expect(startOfDayAt(ts)).toBe(local(2025, 8, 4));
    expect(nextMidnightAfter(ts)).toBe(local(2025, 8, 5));
  });

  it('is idempotent when the instant is already midnight', () => {
    expect(startOfDayAt(local(2025, 8, 4))).toBe(local(2025, 8, 4));
    expect(nextMidnightAfter(local(2025, 8, 4))).toBe(local(2025, 8, 5));
  });

  it('returns DST-correct boundaries', () => {
    expect(nextMidnightAfter(local(2025, 3, 30, 12, 0))).toBe(local(2025, 3, 31));
    expect(nextMidnightAfter(local(2025, 10, 26, 12, 0))).toBe(local(2025, 10, 27));
    expect(startOfDayAt(local(2025, 3, 30, 23, 59))).toBe(local(2025, 3, 30));
  });
});

describe('addDays', () => {
  it('shifts by whole calendar days', () => {
    expect(addDays('2025-08-04', 1)).toBe('2025-08-05');
    expect(addDays('2025-08-04', 0)).toBe('2025-08-04');
    expect(addDays('2025-08-04', -1)).toBe('2025-08-03');
    expect(addDays('2025-08-04', 7)).toBe('2025-08-11');
  });

  it('crosses month, year and leap-day boundaries', () => {
    expect(addDays('2025-08-31', 1)).toBe('2025-09-01');
    expect(addDays('2024-12-31', 1)).toBe('2025-01-01');
    expect(addDays('2025-01-01', -1)).toBe('2024-12-31');
    expect(addDays('2024-02-28', 1)).toBe('2024-02-29');
    expect(addDays('2025-02-28', 1)).toBe('2025-03-01');
  });

  it('crosses both DST transitions without losing or gaining a day', () => {
    expect(addDays('2025-03-29', 1)).toBe('2025-03-30');
    expect(addDays('2025-03-30', 1)).toBe('2025-03-31');
    expect(addDays('2025-03-31', -1)).toBe('2025-03-30');
    expect(addDays('2025-10-25', 1)).toBe('2025-10-26');
    expect(addDays('2025-10-26', 1)).toBe('2025-10-27');
    expect(addDays('2025-10-27', -1)).toBe('2025-10-26');
  });
});

describe('daysBetween', () => {
  it('counts whole calendar days, signed', () => {
    expect(daysBetween('2025-08-04', '2025-08-04')).toBe(0);
    expect(daysBetween('2025-08-04', '2025-08-11')).toBe(7);
    expect(daysBetween('2025-08-11', '2025-08-04')).toBe(-7);
  });

  it('is unaffected by the 23h and 25h days', () => {
    expect(daysBetween('2025-03-29', '2025-03-31')).toBe(2);
    expect(daysBetween('2025-03-31', '2025-03-29')).toBe(-2);
    expect(daysBetween('2025-10-25', '2025-10-27')).toBe(2);
    expect(daysBetween('2025-10-27', '2025-10-25')).toBe(-2);
  });

  it('spans months and years', () => {
    expect(daysBetween('2024-12-30', '2025-01-02')).toBe(3);
    expect(daysBetween('2024-02-01', '2024-03-01')).toBe(29);
    expect(daysBetween('2025-02-01', '2025-03-01')).toBe(28);
  });
});

describe('eachDay', () => {
  it('is inclusive at both ends', () => {
    expect(eachDay('2025-08-04', '2025-08-07')).toEqual([
      '2025-08-04',
      '2025-08-05',
      '2025-08-06',
      '2025-08-07',
    ]);
  });

  it('returns a single day when both ends match', () => {
    expect(eachDay('2025-08-04', '2025-08-04')).toEqual(['2025-08-04']);
  });

  it('returns nothing when the range is reversed', () => {
    expect(eachDay('2025-08-07', '2025-08-04')).toEqual([]);
  });

  it('emits every DST day exactly once', () => {
    expect(eachDay('2025-03-29', '2025-03-31')).toEqual([
      '2025-03-29',
      '2025-03-30',
      '2025-03-31',
    ]);
    expect(eachDay('2025-10-25', '2025-10-27')).toEqual([
      '2025-10-25',
      '2025-10-26',
      '2025-10-27',
    ]);
  });
});

describe('todayKey', () => {
  it('derives the local key of the supplied instant', () => {
    expect(todayKey(local(2025, 8, 4, 0, 0))).toBe('2025-08-04');
    expect(todayKey(local(2025, 8, 4, 23, 59, 59, 999))).toBe('2025-08-04');
  });
});

describe('startOfWeek / endOfWeek', () => {
  // 2025-08-03 Sun, 2025-08-04 Mon, 2025-08-06 Wed, 2025-08-09 Sat, 2025-08-10 Sun.
  it('anchors a midweek date to Monday when weeks start on Monday', () => {
    expect(startOfWeek('2025-08-06', 1)).toBe('2025-08-04');
    expect(endOfWeek('2025-08-06', 1)).toBe('2025-08-10');
  });

  it('anchors the same date to Sunday when weeks start on Sunday', () => {
    expect(startOfWeek('2025-08-06', 0)).toBe('2025-08-03');
    expect(endOfWeek('2025-08-06', 0)).toBe('2025-08-09');
  });

  it('treats Sunday as the end of a Monday-start week and the start of a Sunday-start week', () => {
    expect(startOfWeek('2025-08-03', 1)).toBe('2025-07-28');
    expect(endOfWeek('2025-08-03', 1)).toBe('2025-08-03');
    expect(startOfWeek('2025-08-03', 0)).toBe('2025-08-03');
    expect(endOfWeek('2025-08-03', 0)).toBe('2025-08-09');
  });

  it('leaves the anchor day itself unmoved', () => {
    expect(startOfWeek('2025-08-04', 1)).toBe('2025-08-04');
    expect(startOfWeek('2025-08-10', 0)).toBe('2025-08-10');
  });

  it('produces a 7-day week even when the week contains a DST transition', () => {
    expect(startOfWeek('2025-03-30', 1)).toBe('2025-03-24');
    expect(endOfWeek('2025-03-30', 1)).toBe('2025-03-30');
    expect(startOfWeek('2025-10-26', 0)).toBe('2025-10-26');
    expect(endOfWeek('2025-10-26', 0)).toBe('2025-11-01');
    expect(daysBetween(startOfWeek('2025-10-26', 1), endOfWeek('2025-10-26', 1))).toBe(6);
  });
});

describe('startOfMonth / endOfMonth', () => {
  it('brackets an ordinary month', () => {
    expect(startOfMonth('2025-08-15')).toBe('2025-08-01');
    expect(endOfMonth('2025-08-15')).toBe('2025-08-31');
  });

  it('handles a leap-year February', () => {
    expect(startOfMonth('2024-02-10')).toBe('2024-02-01');
    expect(endOfMonth('2024-02-10')).toBe('2024-02-29');
  });

  it('handles a non-leap February', () => {
    expect(endOfMonth('2025-02-10')).toBe('2025-02-28');
  });

  it('handles December and the DST months', () => {
    expect(startOfMonth('2025-12-05')).toBe('2025-12-01');
    expect(endOfMonth('2025-12-05')).toBe('2025-12-31');
    expect(endOfMonth('2025-03-30')).toBe('2025-03-31');
    expect(endOfMonth('2025-10-26')).toBe('2025-10-31');
    expect(endOfMonth('2025-04-01')).toBe('2025-04-30');
  });
});

describe('formatHM', () => {
  it('renders H:MM without padding the hour', () => {
    expect(formatHM(0)).toBe('0:00');
    expect(formatHM(MINUTE)).toBe('0:01');
    expect(formatHM(HOUR)).toBe('1:00');
    expect(formatHM(6 * HOUR + 24 * MINUTE)).toBe('6:24');
  });

  it('does not wrap at 24 hours', () => {
    expect(formatHM(25 * HOUR)).toBe('25:00');
    expect(formatHM(100 * HOUR + 30 * MINUTE)).toBe('100:30');
  });

  it('truncates rather than rounds, and clamps negatives to zero', () => {
    expect(formatHM(MINUTE - 1)).toBe('0:00');
    expect(formatHM(2 * MINUTE - 1)).toBe('0:01');
    expect(formatHM(-1)).toBe('0:00');
    expect(formatHM(-5 * HOUR)).toBe('0:00');
  });
});

describe('formatHMS', () => {
  it('renders H:MM:SS with padded minutes and seconds', () => {
    expect(formatHMS(0)).toBe('0:00:00');
    expect(formatHMS(HOUR + 2 * MINUTE + 3 * SECOND)).toBe('1:02:03');
    expect(formatHMS(6 * HOUR + 24 * MINUTE + 59 * SECOND)).toBe('6:24:59');
  });

  it('does not wrap at 24 hours', () => {
    expect(formatHMS(25 * HOUR + SECOND)).toBe('25:00:01');
  });

  it('truncates sub-second remainders and clamps negatives to zero', () => {
    expect(formatHMS(999)).toBe('0:00:00');
    expect(formatHMS(SECOND - 1)).toBe('0:00:00');
    expect(formatHMS(-1)).toBe('0:00:00');
    expect(formatHMS(-90 * SECOND)).toBe('0:00:00');
  });
});

describe('formatCompact', () => {
  it('drops the hour part under an hour', () => {
    expect(formatCompact(0)).toBe('0m');
    expect(formatCompact(24 * MINUTE)).toBe('24m');
    expect(formatCompact(59 * MINUTE)).toBe('59m');
  });

  it('drops the minute part on a whole hour', () => {
    expect(formatCompact(HOUR)).toBe('1h');
    expect(formatCompact(25 * HOUR)).toBe('25h');
  });

  it('renders both parts otherwise', () => {
    expect(formatCompact(HOUR + 24 * MINUTE)).toBe('1h 24m');
    expect(formatCompact(7 * HOUR + 45 * MINUTE)).toBe('7h 45m');
  });

  it('clamps negatives to zero', () => {
    expect(formatCompact(-1)).toBe('0m');
    expect(formatCompact(-3 * HOUR)).toBe('0m');
  });
});

describe('formatClock / formatClockSeconds / formatDateLong', () => {
  it('renders the local wall clock, zero-padded', () => {
    expect(formatClock(local(2025, 8, 4, 9, 5))).toBe('09:05');
    expect(formatClock(local(2025, 8, 4, 23, 59))).toBe('23:59');
    expect(formatClock(local(2025, 8, 4, 0, 0))).toBe('00:00');
    expect(formatClockSeconds(local(2025, 8, 4, 9, 5, 7))).toBe('09:05:07');
  });

  it('reads the post-transition wall clock across DST', () => {
    // 02:00 does not exist on 2025-03-30, so one hour past midnight + 1h is 03:00.
    expect(formatClock(startOfDay('2025-03-30') + 2 * HOUR)).toBe('03:00');
    // 02:30 happens twice on 2025-10-26; both render identically.
    expect(formatClock(local(2025, 10, 26, 2, 30))).toBe('02:30');
    expect(formatClock(local(2025, 10, 26, 2, 30) + HOUR)).toBe('02:30');
  });

  it('includes the weekday, day, month and year', () => {
    const rendered = formatDateLong('2025-08-04');
    expect(rendered).toContain('2025');
    expect(rendered).toContain('4');
  });
});

describe('fromTimeInputValue / toTimeInputValue', () => {
  it('combines a date key with a local time of day', () => {
    expect(fromTimeInputValue('2025-08-04', '09:30')).toBe(local(2025, 8, 4, 9, 30));
    expect(fromTimeInputValue('2025-08-04', '00:00')).toBe(local(2025, 8, 4, 0, 0));
    expect(fromTimeInputValue('2025-08-04', '23:59')).toBe(local(2025, 8, 4, 23, 59));
  });

  it('accepts an optional seconds component and zeroes the milliseconds', () => {
    expect(fromTimeInputValue('2025-08-04', '09:30:45')).toBe(local(2025, 8, 4, 9, 30, 45));
    expect(fromTimeInputValue('2025-08-04', '09:30')).toBe(local(2025, 8, 4, 9, 30, 0, 0));
  });

  it('round-trips through toTimeInputValue', () => {
    for (const time of ['00:00', '07:05', '12:00', '18:45', '23:59']) {
      const ts = requireInstant(fromTimeInputValue('2025-08-04', time));
      expect(toTimeInputValue(ts)).toBe(time);
    }
  });

  it('drops the seconds on the way back out, as the H:MM input field requires', () => {
    const ts = requireInstant(fromTimeInputValue('2025-08-04', '09:30:45'));
    expect(toTimeInputValue(ts)).toBe('09:30');
  });

  it('round-trips the repeated hour of the 25h day to its first occurrence', () => {
    const ts = requireInstant(fromTimeInputValue('2025-10-26', '02:30'));
    expect(ts).toBe(local(2025, 10, 26, 2, 30));
    expect(toTimeInputValue(ts)).toBe('02:30');
  });

  it('resolves the non-existent hour of the 23h day forward, so it does not round-trip', () => {
    // 02:30 never happens on 2025-03-30; `Date` lands on 03:30 and that is the only
    // sane instant to store. Callers must re-read the field after saving.
    const ts = requireInstant(fromTimeInputValue('2025-03-30', '02:30'));
    expect(ts).toBe(local(2025, 3, 30, 3, 30));
    expect(toTimeInputValue(ts)).toBe('03:30');
  });

  it('rejects the wrong number of components', () => {
    expect(fromTimeInputValue('2025-08-04', '')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '0930')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '9')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:30:45:00')).toBeNull();
  });

  it('rejects non-integer components', () => {
    expect(fromTimeInputValue('2025-08-04', 'ab:cd')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:3o')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '9.5:30')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:30.5')).toBeNull();
  });

  it('rejects out-of-range components', () => {
    expect(fromTimeInputValue('2025-08-04', '24:00')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '-1:00')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:60')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:-1')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:30:60')).toBeNull();
  });

  // Regression guard: `Number()` coercion alone accepts hex, exponent, whitespace-padded,
  // signed and empty components, so strings that are plainly not `HH:MM` used to be
  // parsed instead of returning null. Each component is now digit-checked first.
  it('rejects components that only Number() would accept', () => {
    expect(fromTimeInputValue('2025-08-04', '0x10:30')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '1e1:30')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', ' 9:30')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '+9:30')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', '09:')).toBeNull();
    expect(fromTimeInputValue('2025-08-04', ':30')).toBeNull();
  });
});

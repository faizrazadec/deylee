/**
 * Range roll-ups for the History window: week totals, month totals, daily average.
 */

import { eachDay, startOfWeek, endOfWeek, startOfMonth, endOfMonth } from '../shared/time';
import type { WeekStart } from '../shared/time';
import type { DateKey, DateRange, DayDetail, RangeSummary } from '../shared/types';

/**
 * Summarise a set of days.
 *
 * The daily average deliberately divides by *active* days — days with recorded work
 * — not by calendar days in the range, so a month average is not dragged down by
 * weekends and holidays.
 */
export function summariseRange(range: DateRange, days: readonly DayDetail[]): RangeSummary {
  let totalWorkedMs = 0;
  let totalBreakMs = 0;
  let activeDayCount = 0;
  let targetMetCount = 0;

  for (const detail of days) {
    totalWorkedMs += detail.totals.workedMs;
    totalBreakMs += detail.totals.breakMs;
    if (detail.totals.workedMs > 0) {
      activeDayCount += 1;
      const targetMs = detail.day.targetMinutes * 60_000;
      if (targetMs > 0 && detail.totals.workedMs >= targetMs) targetMetCount += 1;
    }
  }

  return {
    range,
    days: [...days],
    totalWorkedMs,
    totalBreakMs,
    activeDayCount,
    averageWorkedMsPerActiveDay: activeDayCount === 0 ? 0 : totalWorkedMs / activeDayCount,
    targetMetCount,
  };
}

/** Fill in zero-total placeholders so a calendar grid has an entry for every day. */
export function densifyRange(range: DateRange, days: readonly DayDetail[]): Map<DateKey, DayDetail | null> {
  const byDate = new Map<DateKey, DayDetail>();
  for (const detail of days) byDate.set(detail.day.date, detail);

  const out = new Map<DateKey, DayDetail | null>();
  for (const date of eachDay(range.from, range.to)) {
    out.set(date, byDate.get(date) ?? null);
  }
  return out;
}

export function weekRange(date: DateKey, weekStartsOn: WeekStart): DateRange {
  return { from: startOfWeek(date, weekStartsOn), to: endOfWeek(date, weekStartsOn) };
}

export function monthRange(date: DateKey): DateRange {
  return { from: startOfMonth(date), to: endOfMonth(date) };
}

/** Totals for the ISO-ish week containing `date`, taken from an already-loaded range. */
export function subRange(days: readonly DayDetail[], range: DateRange): RangeSummary {
  const within = days.filter((d) => d.day.date >= range.from && d.day.date <= range.to);
  return summariseRange(range, within);
}

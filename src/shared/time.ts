/**
 * Local-calendar time helpers.
 *
 * Rules that hold everywhere in Dayly:
 *  - Instants are UTC epoch milliseconds. Nothing else is ever persisted.
 *  - A "day" is a *local* calendar day, so it may be 23h or 25h long across DST.
 *    All boundary maths therefore goes through the `Date(y, m, d, ...)` constructor,
 *    which resolves in local time, rather than adding fixed millisecond offsets.
 *  - `DateKey` is `YYYY-MM-DD` and is only ever produced by `dateKeyOf`.
 *
 * These functions are pure and are shared by the main process, the renderers and
 * the unit tests.
 */

import type { DateKey, EpochMs } from './types';

export const MS_PER_SECOND = 1_000;
export const MS_PER_MINUTE = 60_000;
export const MS_PER_HOUR = 3_600_000;

const DATE_KEY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
/** One or two plain digits — no sign, no radix prefix, no exponent, no whitespace. */
const TIME_COMPONENT = /^\d{1,2}$/;

function pad2(value: number): string {
  return value < 10 ? `0${value}` : String(value);
}

/** The local calendar date containing `ts`. */
export function dateKeyOf(ts: EpochMs): DateKey {
  const d = new Date(ts);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function isDateKey(value: string): value is DateKey {
  if (!DATE_KEY_PATTERN.test(value)) return false;
  const [y, m, d] = value.split('-').map(Number);
  if (m < 1 || m > 12 || d < 1 || d > 31) return false;
  const probe = new Date(y, m - 1, d);
  return probe.getFullYear() === y && probe.getMonth() === m - 1 && probe.getDate() === d;
}

/**
 * Midnight (00:00:00.000 local) at the start of the given date key.
 *
 * On a spring-forward DST day in zones where the transition happens *at* midnight
 * (e.g. America/Santiago), local midnight does not exist. `Date` resolves that to
 * 01:00, which is the correct start-of-day instant for our purposes.
 */
export function startOfDay(date: DateKey): EpochMs {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(y, m - 1, d, 0, 0, 0, 0).getTime();
}

/** Midnight at the start of the local day containing `ts`. */
export function startOfDayAt(ts: EpochMs): EpochMs {
  return startOfDay(dateKeyOf(ts));
}

/** The instant the given local day ends — i.e. the start of the next day. */
export function endOfDay(date: DateKey): EpochMs {
  return startOfDay(addDays(date, 1));
}

/** Start of the next local day after `ts`. Handles 23h/25h DST days. */
export function nextMidnightAfter(ts: EpochMs): EpochMs {
  return endOfDay(dateKeyOf(ts));
}

/** Shift a date key by whole calendar days. */
export function addDays(date: DateKey, days: number): DateKey {
  const [y, m, d] = date.split('-').map(Number);
  return dateKeyOf(new Date(y, m - 1, d + days, 12, 0, 0, 0).getTime());
}

/** Whole calendar days from `from` to `to`; negative when `to` precedes `from`. */
export function daysBetween(from: DateKey, to: DateKey): number {
  const [fy, fm, fd] = from.split('-').map(Number);
  const [ty, tm, td] = to.split('-').map(Number);
  // Noon anchors keep the difference DST-proof before rounding.
  const a = new Date(fy, fm - 1, fd, 12).getTime();
  const b = new Date(ty, tm - 1, td, 12).getTime();
  return Math.round((b - a) / (24 * MS_PER_HOUR));
}

/** Every date key from `from` to `to`, inclusive. Empty when `to` precedes `from`. */
export function eachDay(from: DateKey, to: DateKey): DateKey[] {
  const span = daysBetween(from, to);
  if (span < 0) return [];
  const out: DateKey[] = [];
  for (let i = 0; i <= span; i += 1) out.push(addDays(from, i));
  return out;
}

export function todayKey(now: EpochMs = Date.now()): DateKey {
  return dateKeyOf(now);
}

/* -------------------------------------------------------------------------- */
/* Week / month ranges                                                         */
/* -------------------------------------------------------------------------- */

export type WeekStart = 0 | 1;

/** The date key of the first day of the week containing `date`. */
export function startOfWeek(date: DateKey, weekStartsOn: WeekStart): DateKey {
  const [y, m, d] = date.split('-').map(Number);
  const dow = new Date(y, m - 1, d, 12).getDay();
  const delta = (dow - weekStartsOn + 7) % 7;
  return addDays(date, -delta);
}

export function endOfWeek(date: DateKey, weekStartsOn: WeekStart): DateKey {
  return addDays(startOfWeek(date, weekStartsOn), 6);
}

export function startOfMonth(date: DateKey): DateKey {
  const [y, m] = date.split('-').map(Number);
  return `${y}-${pad2(m)}-01`;
}

export function endOfMonth(date: DateKey): DateKey {
  const [y, m] = date.split('-').map(Number);
  // Day 0 of the next month is the last day of this one.
  return dateKeyOf(new Date(y, m, 0, 12).getTime());
}

/* -------------------------------------------------------------------------- */
/* Formatting                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * `H:MM` — the macOS menu-bar format. Hours are not zero-padded and are not
 * wrapped at 24. Negative inputs clamp to zero.
 */
export function formatHM(ms: number): string {
  const total = Math.max(0, Math.floor(ms / MS_PER_MINUTE));
  return `${Math.floor(total / 60)}:${pad2(total % 60)}`;
}

/** `H:MM:SS`, for the big live timer. */
export function formatHMS(ms: number): string {
  const total = Math.max(0, Math.floor(ms / MS_PER_SECOND));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}:${pad2(m)}:${pad2(s)}`;
}

/** `1h 24m`, or `24m` under an hour, or `0m` when empty. */
export function formatCompact(ms: number): string {
  const total = Math.max(0, Math.floor(ms / MS_PER_MINUTE));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `${h}h` : `${h}h ${m}m`;
}

/** Local wall-clock `HH:MM` for an instant. */
export function formatClock(ts: EpochMs): string {
  const d = new Date(ts);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

/** Local wall-clock `HH:MM:SS` for an instant. */
export function formatClockSeconds(ts: EpochMs): string {
  const d = new Date(ts);
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
}

/** `Mon 4 Aug 2025`, using the host locale's month/weekday names. */
export function formatDateLong(date: DateKey): string {
  const [y, m, d] = date.split('-').map(Number);
  return new Date(y, m - 1, d, 12).toLocaleDateString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  });
}

/** `HH:MM` for a local time-of-day input field. */
export function toTimeInputValue(ts: EpochMs): string {
  return formatClock(ts);
}

/**
 * Combine a date key with an `HH:MM` (or `HH:MM:SS`) local time into an instant.
 * Returns `null` when the time string is malformed.
 */
export function fromTimeInputValue(date: DateKey, time: string): EpochMs | null {
  if (!isDateKey(date)) return null;
  const parts = time.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  const [hh, mm, ss = '0'] = parts;
  // Each component must be plain digits. `Number()` alone is far too permissive here:
  // it happily accepts '0x10', '1e1', ' 9', '+9', and turns '' into 0 — so '09:' and
  // ':30' would parse to a real time instead of being rejected.
  if (!TIME_COMPONENT.test(hh) || !TIME_COMPONENT.test(mm) || !TIME_COMPONENT.test(ss)) {
    return null;
  }
  const h = Number(hh);
  const m = Number(mm);
  const s = Number(ss);
  if (h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59) return null;
  const [y, mo, d] = date.split('-').map(Number);
  return new Date(y, mo - 1, d, h, m, s, 0).getTime();
}

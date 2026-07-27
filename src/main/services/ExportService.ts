/**
 * Export serialisation.
 *
 * Pure string building, no Electron and no filesystem: the save dialog and the write
 * belong to the IPC layer, which keeps both formats testable against plain literals.
 *
 * Every row carries both the local wall-clock time (what the user recognises) and the
 * raw UTC epoch milliseconds (what round-trips exactly). A spreadsheet opened in
 * another timezone would silently rewrite the first; the second is the ground truth.
 */

import { formatClockSeconds, MS_PER_MINUTE } from '@shared/time';
import type { DateKey, DateRange, DayDetail, DayTotals, EpochMs, Segment } from '@shared/types';

const CSV_HEADER =
  'date,segment_type,started_at_local,ended_at_local,duration_minutes,started_at_utc_ms,ended_at_utc_ms,note';

/** RFC 4180: only these characters force a field to be quoted. */
const CSV_NEEDS_QUOTING = /["\r\n,]/;

const CSV_COLUMN_COUNT = 8;

export interface JsonExportDay {
  date: DateKey;
  targetMinutes: number;
  totals: DayTotals;
  segments: Segment[];
}

export interface JsonExport {
  /** ISO-8601 UTC instant. This file is read outside the app, where an epoch is opaque. */
  exportedAt: string;
  range: DateRange;
  days: JsonExportDay[];
}

export function buildCsv(days: readonly DayDetail[]): string {
  const lines: string[] = [CSV_HEADER];

  for (const detail of orderedDays(days)) {
    const segments = orderedSegments(detail.segments);
    if (segments.length === 0) {
      // A day the user opened and recorded nothing on is still a fact about the range,
      // so it gets a row rather than vanishing from the file.
      lines.push(csvRow([detail.day.date, ...emptyFields(CSV_COLUMN_COUNT - 1)]));
      continue;
    }
    for (const segment of segments) {
      lines.push(csvRow(csvFieldsFor(detail.day.date, segment)));
    }
  }

  return lines.join('\n');
}

export function buildJson(days: readonly DayDetail[], range: DateRange): string {
  const payload: JsonExport = {
    exportedAt: new Date().toISOString(),
    range,
    days: orderedDays(days).map((detail) => ({
      date: detail.day.date,
      targetMinutes: detail.day.targetMinutes,
      totals: detail.totals,
      segments: orderedSegments(detail.segments),
    })),
  };
  return JSON.stringify(payload, null, 2);
}

/* -------------------------------------------------------------------------- */
/* Internals                                                                   */
/* -------------------------------------------------------------------------- */

function csvFieldsFor(date: DateKey, segment: Segment): string[] {
  // An open segment has no end, and its duration would depend on the instant of the
  // export, so both stay empty rather than baking "now" into the file.
  const endedAt = segment.endedAt;
  return [
    date,
    segment.type,
    formatClockSeconds(segment.startedAt),
    endedAt === null ? '' : formatClockSeconds(endedAt),
    endedAt === null ? '' : durationMinutes(segment.startedAt, endedAt),
    String(segment.startedAt),
    endedAt === null ? '' : String(endedAt),
    segment.note ?? '',
  ];
}

/**
 * Two decimals rather than whole minutes: rounding to the nearest minute would report
 * a 40-second segment as `0`, which reads as a bug in a spreadsheet.
 */
function durationMinutes(startedAt: EpochMs, endedAt: EpochMs): string {
  const minutes = Math.max(0, endedAt - startedAt) / MS_PER_MINUTE;
  return String(Number(minutes.toFixed(2)));
}

function csvRow(fields: readonly string[]): string {
  return fields.map((field) => csvField(field)).join(',');
}

function csvField(value: string): string {
  if (!CSV_NEEDS_QUOTING.test(value)) return value;
  return `"${value.replace(/"/g, '""')}"`;
}

function emptyFields(count: number): string[] {
  return new Array<string>(count).fill('');
}

/** Date keys are `YYYY-MM-DD`, so a plain comparison is a chronological one. */
function orderedDays(days: readonly DayDetail[]): DayDetail[] {
  return [...days].sort((a, b) => {
    if (a.day.date < b.day.date) return -1;
    return a.day.date > b.day.date ? 1 : 0;
  });
}

function orderedSegments(segments: readonly Segment[]): Segment[] {
  return [...segments].sort((a, b) => a.startedAt - b.startedAt);
}

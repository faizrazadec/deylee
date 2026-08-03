/**
 * Tests for overlap validation.
 *
 * The load-bearing rule is that intervals are half-open, `[startedAt, endedAt)`:
 * a pause immediately followed by a resume produces two segments that share an
 * instant, and that must stay legal or the timer could never pause.
 */

import { describe, expect, it } from 'vitest';
import {
  findOpenSegments,
  findOverlapping,
  intervalsOverlap,
  validateSegment,
} from '@domain/overlap';
import type { Interval } from '@domain/overlap';
import type { Segment, SegmentType } from '@shared/types';

function local(y: number, m: number, d: number, h = 0, min = 0): number {
  return new Date(y, m - 1, d, h, min, 0, 0).getTime();
}

/** Hours on 2025-08-04, the ordinary day every case in this file lives on. */
function at(h: number, min = 0): number {
  return local(2025, 8, 4, h, min);
}

function interval(startedAt: number, endedAt: number | null): Interval {
  return { startedAt, endedAt };
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

describe('intervalsOverlap', () => {
  it('is false for disjoint intervals, in either argument order', () => {
    const a = interval(at(9), at(10));
    const b = interval(at(11), at(12));
    expect(intervalsOverlap(a, b)).toBe(false);
    expect(intervalsOverlap(b, a)).toBe(false);
  });

  it('is false when the endpoints merely touch — the pause/resume boundary', () => {
    const work = interval(at(9), at(12));
    const pause = interval(at(12), at(12, 45));
    expect(intervalsOverlap(work, pause)).toBe(false);
    expect(intervalsOverlap(pause, work)).toBe(false);
  });

  it('is true when the intervals share any positive-length span', () => {
    const a = interval(at(9), at(12));
    const b = interval(at(11, 59), at(13));
    expect(intervalsOverlap(a, b)).toBe(true);
    expect(intervalsOverlap(b, a)).toBe(true);
  });

  it('is true when one interval contains the other', () => {
    const outer = interval(at(9), at(17));
    const inner = interval(at(11), at(12));
    expect(intervalsOverlap(outer, inner)).toBe(true);
    expect(intervalsOverlap(inner, outer)).toBe(true);
  });

  it('is true for identical intervals', () => {
    expect(intervalsOverlap(interval(at(9), at(12)), interval(at(9), at(12)))).toBe(true);
  });

  it('treats an open-ended interval as running forever', () => {
    const open = interval(at(9), null);
    expect(intervalsOverlap(open, interval(at(20), at(21)))).toBe(true);
    expect(intervalsOverlap(interval(at(20), at(21)), open)).toBe(true);
    expect(intervalsOverlap(open, interval(at(7), at(8)))).toBe(false);
  });

  it('lets a closed interval end exactly where an open one begins', () => {
    const closed = interval(at(9), at(12));
    const open = interval(at(12), null);
    expect(intervalsOverlap(closed, open)).toBe(false);
    expect(intervalsOverlap(open, closed)).toBe(false);
  });

  it('is true for two open-ended intervals, whatever their starts', () => {
    expect(intervalsOverlap(interval(at(9), null), interval(at(15), null))).toBe(true);
  });

  it('is false for a reversed interval that no longer covers anything', () => {
    expect(intervalsOverlap(interval(at(13), at(11)), interval(at(9), at(12)))).toBe(false);
  });
});

describe('findOverlapping', () => {
  const existing = [
    segment(1, 'work', at(9), at(12)),
    segment(2, 'break', at(12), at(12, 45)),
    segment(3, 'work', at(12, 45), at(17)),
  ];

  it('returns null when nothing conflicts', () => {
    expect(findOverlapping(interval(at(17), at(18)), existing)).toBeNull();
    expect(findOverlapping(interval(at(7), at(9)), existing)).toBeNull();
    expect(findOverlapping(interval(at(9), at(12)), [])).toBeNull();
  });

  it('returns the first conflicting segment in list order', () => {
    // Spans all three; the first one encountered wins.
    expect(findOverlapping(interval(at(10), at(16)), existing)?.id).toBe(1);
    expect(findOverlapping(interval(at(12, 30), at(16)), existing)?.id).toBe(2);
    expect(findOverlapping(interval(at(13), at(16)), existing)?.id).toBe(3);
  });

  it('ignores the segment being edited', () => {
    // Nudging segment 2's end later only clashes with itself and with segment 3.
    expect(findOverlapping(interval(at(12), at(12, 30)), existing, 2)).toBeNull();
    expect(findOverlapping(interval(at(12), at(13)), existing, 2)?.id).toBe(3);
  });

  it('only ignores the id it was given', () => {
    expect(findOverlapping(interval(at(10), at(11)), existing, 3)?.id).toBe(1);
    expect(findOverlapping(interval(at(10), at(11)), existing, 999)?.id).toBe(1);
  });

  it('finds a conflict with a stored open segment', () => {
    const withOpen = [segment(7, 'work', at(9), null)];
    expect(findOverlapping(interval(at(22), at(23)), withOpen)?.id).toBe(7);
    expect(findOverlapping(interval(at(7), at(9)), withOpen)).toBeNull();
  });
});

describe('validateSegment', () => {
  const existing = [
    segment(1, 'work', at(9), at(12)),
    segment(2, 'break', at(12), at(12, 45)),
  ];

  it('accepts a well-formed candidate in free time', () => {
    const candidate = interval(at(13), at(17));
    const result = validateSegment(candidate, existing);

    expect(result.ok).toBe(true);
    expect(result).toEqual({ ok: true, value: candidate });
  });

  it('accepts a candidate that exactly abuts its neighbours', () => {
    expect(validateSegment(interval(at(12, 45), at(17)), existing).ok).toBe(true);
    expect(validateSegment(interval(at(7), at(9)), existing).ok).toBe(true);
  });

  it('accepts an open-ended candidate that starts after everything else', () => {
    const result = validateSegment(interval(at(12, 45), null), existing);
    expect(result.ok).toBe(true);
  });

  it('accepts an edit of an existing segment when it is excluded from the comparison', () => {
    expect(validateSegment(interval(at(9), at(11, 30)), existing, 1).ok).toBe(true);
  });

  it('rejects a reversed range', () => {
    const result = validateSegment(interval(at(17), at(13)), existing);
    expect(result).toEqual({
      ok: false,
      code: 'invalid-range',
      message: 'End time is before the start time.',
    });
  });

  it('rejects a zero-length range', () => {
    const result = validateSegment(interval(at(13), at(13)), existing);
    expect(result).toEqual({
      ok: false,
      code: 'invalid-range',
      message: 'Start and end time are the same.',
    });
  });

  it('rejects non-finite instants', () => {
    expect(validateSegment(interval(Number.NaN, at(13)), existing)).toEqual({
      ok: false,
      code: 'invalid-range',
      message: 'Start time is not a valid instant.',
    });
    expect(validateSegment(interval(at(13), Number.NaN), existing)).toEqual({
      ok: false,
      code: 'invalid-range',
      message: 'End time is not a valid instant.',
    });
    expect(validateSegment(interval(at(13), Number.POSITIVE_INFINITY), existing)).toEqual({
      ok: false,
      code: 'invalid-range',
      message: 'End time is not a valid instant.',
    });
    expect(validateSegment(interval(Number.NaN, null), existing)).toEqual({
      ok: false,
      code: 'invalid-range',
      message: 'Start time is not a valid instant.',
    });
  });

  it('checks the range before the overlap, so a reversed clash reports the range', () => {
    const result = validateSegment(interval(at(12), at(10)), existing);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.code).toBe('invalid-range');
  });

  it('rejects an overlap and names the clashing segment in local wall-clock time', () => {
    const result = validateSegment(interval(at(11), at(13)), existing);
    expect(result).toEqual({
      ok: false,
      code: 'overlap',
      message: 'Overlaps the work segment from 09:00 to 12:00.',
    });
  });

  it('describes a clash with an open segment as ending "now"', () => {
    const result = validateSegment(interval(at(15), at(16)), [segment(9, 'break', at(14), null)]);
    expect(result).toEqual({
      ok: false,
      code: 'overlap',
      message: 'Overlaps the break segment from 14:00 to now.',
    });
  });

  it('rejects an open-ended candidate that swallows a later segment', () => {
    const result = validateSegment(interval(at(11), null), existing);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.code).toBe('overlap');
  });

  it('accepts anything when there are no other segments', () => {
    expect(validateSegment(interval(at(9), at(17)), []).ok).toBe(true);
  });
});

describe('findOpenSegments', () => {
  it('returns only the segments with no end', () => {
    const segments = [
      segment(1, 'work', at(9), at(12)),
      segment(2, 'break', at(12), null),
      segment(3, 'work', at(13), null),
    ];
    expect(findOpenSegments(segments).map((s) => s.id)).toEqual([2, 3]);
  });

  it('returns an empty list when everything is closed', () => {
    expect(findOpenSegments([segment(1, 'work', at(9), at(12))])).toEqual([]);
    expect(findOpenSegments([])).toEqual([]);
  });
});

/**
 * Tests for midnight splitting.
 *
 * The invariants that matter to the repository are: pieces are contiguous, their
 * durations sum to the original span, every boundary is a real local midnight, and
 * each piece is tagged with the day it actually belongs to. TZ=Europe/Berlin makes
 * 2025-03-30 a 23-hour day and 2025-10-26 a 25-hour day, so a naive +24h boundary
 * would be caught here.
 */

import { describe, expect, it } from 'vitest';
import { crossesMidnight, splitAtMidnight, splitOpenSpanAt } from '@domain/midnight';
import type { DaySpan, SplittableSpan } from '@domain/midnight';
import type { SegmentType } from '@shared/types';

const HOUR = 3_600_000;
const MINUTE = 60_000;

function local(y: number, m: number, d: number, h = 0, min = 0, s = 0, ms = 0): number {
  return new Date(y, m - 1, d, h, min, s, ms).getTime();
}

function span(type: SegmentType, startedAt: number, endedAt: number | null): SplittableSpan {
  return { type, startedAt, endedAt };
}

/** piece[n].endedAt must equal piece[n + 1].startedAt — no gaps, no double counting. */
function expectContiguous(pieces: readonly DaySpan[]): void {
  for (let i = 1; i < pieces.length; i += 1) {
    expect(pieces[i - 1].endedAt).toBe(pieces[i].startedAt);
  }
}

function closedTotal(pieces: readonly DaySpan[]): number {
  let total = 0;
  for (const piece of pieces) {
    if (piece.endedAt === null) throw new Error('expected every piece to be closed');
    total += piece.endedAt - piece.startedAt;
  }
  return total;
}

describe('crossesMidnight', () => {
  it('is false for a span that starts and ends on the same local day', () => {
    expect(crossesMidnight(span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 17, 0)))).toBe(
      false,
    );
    expect(crossesMidnight(span('work', local(2025, 8, 4, 0, 0), local(2025, 8, 4, 23, 59)))).toBe(
      false,
    );
  });

  it('is false for an open span — it is split when it closes, not before', () => {
    expect(crossesMidnight(span('work', local(2025, 8, 3, 22, 0), null))).toBe(false);
  });

  it('is false for reversed and zero-length spans', () => {
    expect(crossesMidnight(span('work', local(2025, 8, 5, 1, 0), local(2025, 8, 4, 23, 0)))).toBe(
      false,
    );
    const at = local(2025, 8, 4, 12, 0);
    expect(crossesMidnight(span('work', at, at))).toBe(false);
  });

  it('is true for a span that runs into the next day', () => {
    expect(crossesMidnight(span('work', local(2025, 8, 4, 22, 0), local(2025, 8, 5, 1, 30)))).toBe(
      true,
    );
    expect(crossesMidnight(span('work', local(2025, 8, 4, 22, 0), local(2025, 8, 7, 5, 0)))).toBe(
      true,
    );
  });

  it('is true for a span ending exactly at midnight, which splitAtMidnight leaves whole', () => {
    // Midnight belongs to the following day key, so the cheap pre-check says "yes" while
    // the splitter still returns a single piece. Callers must not assume the two agree.
    const ends = span('work', local(2025, 8, 4, 21, 0), local(2025, 8, 5, 0, 0));
    expect(crossesMidnight(ends)).toBe(true);
    expect(splitAtMidnight(ends)).toHaveLength(1);
  });

  it('detects the crossing on both DST days', () => {
    expect(crossesMidnight(span('work', local(2025, 3, 29, 23, 0), local(2025, 3, 30, 1, 0)))).toBe(
      true,
    );
    expect(
      crossesMidnight(span('work', local(2025, 10, 25, 23, 0), local(2025, 10, 26, 1, 0))),
    ).toBe(true);
  });
});

describe('splitAtMidnight', () => {
  it('returns a same-day span unchanged, tagged with its day', () => {
    const same = span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 17, 0));
    expect(splitAtMidnight(same)).toEqual([
      {
        date: '2025-08-04',
        type: 'work',
        startedAt: local(2025, 8, 4, 9, 0),
        endedAt: local(2025, 8, 4, 17, 0),
      },
    ]);
  });

  it('splits a span crossing one midnight into two contiguous pieces', () => {
    const pieces = splitAtMidnight(span('work', local(2025, 8, 4, 22, 0), local(2025, 8, 5, 1, 30)));

    expect(pieces).toEqual([
      {
        date: '2025-08-04',
        type: 'work',
        startedAt: local(2025, 8, 4, 22, 0),
        endedAt: local(2025, 8, 5, 0, 0),
      },
      {
        date: '2025-08-05',
        type: 'work',
        startedAt: local(2025, 8, 5, 0, 0),
        endedAt: local(2025, 8, 5, 1, 30),
      },
    ]);
    expectContiguous(pieces);
    expect(closedTotal(pieces)).toBe(3 * HOUR + 30 * MINUTE);
  });

  it('preserves the segment type on every piece', () => {
    const pieces = splitAtMidnight(
      span('break', local(2025, 8, 4, 23, 30), local(2025, 8, 5, 0, 30)),
    );
    expect(pieces.map((piece) => piece.type)).toEqual(['break', 'break']);
  });

  it('splits a span across several days into one piece per day', () => {
    const pieces = splitAtMidnight(span('work', local(2025, 8, 4, 22, 0), local(2025, 8, 7, 5, 0)));

    expect(pieces.map((piece) => piece.date)).toEqual([
      '2025-08-04',
      '2025-08-05',
      '2025-08-06',
      '2025-08-07',
    ]);
    expect(pieces.map((piece) => piece.endedAt)).toEqual([
      local(2025, 8, 5, 0, 0),
      local(2025, 8, 6, 0, 0),
      local(2025, 8, 7, 0, 0),
      local(2025, 8, 7, 5, 0),
    ]);
    expectContiguous(pieces);
    expect(closedTotal(pieces)).toBe(55 * HOUR);
  });

  it('does not emit an empty trailing piece for a span ending exactly at midnight', () => {
    const pieces = splitAtMidnight(span('work', local(2025, 8, 4, 21, 0), local(2025, 8, 5, 0, 0)));

    expect(pieces).toEqual([
      {
        date: '2025-08-04',
        type: 'work',
        startedAt: local(2025, 8, 4, 21, 0),
        endedAt: local(2025, 8, 5, 0, 0),
      },
    ]);
  });

  it('does not emit an empty trailing piece after a multi-day span ending at midnight', () => {
    const pieces = splitAtMidnight(span('work', local(2025, 8, 4, 21, 0), local(2025, 8, 6, 0, 0)));
    expect(pieces).toHaveLength(2);
    expect(pieces[1]).toEqual({
      date: '2025-08-05',
      type: 'work',
      startedAt: local(2025, 8, 5, 0, 0),
      endedAt: local(2025, 8, 6, 0, 0),
    });
  });

  it('returns an open span as a single open piece', () => {
    expect(splitAtMidnight(span('work', local(2025, 8, 3, 22, 0), null))).toEqual([
      {
        date: '2025-08-03',
        type: 'work',
        startedAt: local(2025, 8, 3, 22, 0),
        endedAt: null,
      },
    ]);
  });

  it('returns a reversed span unchanged, leaving rejection to the caller', () => {
    const reversed = span('work', local(2025, 8, 5, 1, 0), local(2025, 8, 4, 23, 0));
    expect(splitAtMidnight(reversed)).toEqual([
      {
        date: '2025-08-05',
        type: 'work',
        startedAt: local(2025, 8, 5, 1, 0),
        endedAt: local(2025, 8, 4, 23, 0),
      },
    ]);
  });

  it('returns a zero-length span unchanged', () => {
    const at = local(2025, 8, 4, 12, 0);
    expect(splitAtMidnight(span('break', at, at))).toEqual([
      { date: '2025-08-04', type: 'break', startedAt: at, endedAt: at },
    ]);
  });

  it('splits across the 23-hour spring-forward day at the right instants', () => {
    const pieces = splitAtMidnight(
      span('work', local(2025, 3, 29, 23, 0), local(2025, 3, 31, 1, 0)),
    );

    expect(pieces.map((piece) => piece.date)).toEqual([
      '2025-03-29',
      '2025-03-30',
      '2025-03-31',
    ]);
    expect(pieces.map((piece) => piece.startedAt)).toEqual([
      local(2025, 3, 29, 23, 0),
      local(2025, 3, 30, 0, 0),
      local(2025, 3, 31, 0, 0),
    ]);
    expect(closedTotal([pieces[1]])).toBe(23 * HOUR);
    expectContiguous(pieces);
    expect(closedTotal(pieces)).toBe(25 * HOUR);
  });

  it('splits across the 25-hour fall-back day at the right instants', () => {
    const pieces = splitAtMidnight(
      span('work', local(2025, 10, 25, 23, 0), local(2025, 10, 27, 1, 0)),
    );

    expect(pieces.map((piece) => piece.date)).toEqual([
      '2025-10-25',
      '2025-10-26',
      '2025-10-27',
    ]);
    expect(pieces.map((piece) => piece.startedAt)).toEqual([
      local(2025, 10, 25, 23, 0),
      local(2025, 10, 26, 0, 0),
      local(2025, 10, 27, 0, 0),
    ]);
    expect(closedTotal([pieces[1]])).toBe(25 * HOUR);
    expectContiguous(pieces);
    expect(closedTotal(pieces)).toBe(27 * HOUR);
  });

  it('splits a span that ends inside the skipped hour of the 23-hour day', () => {
    // 02:30 does not exist on 2025-03-30; `Date` resolves it to 03:30 CEST. The clock
    // then reads 3h30m past midnight but only 2h30m of real time has elapsed.
    const pieces = splitAtMidnight(
      span('work', local(2025, 3, 29, 22, 0), local(2025, 3, 30, 2, 30)),
    );

    expect(pieces).toHaveLength(2);
    expect(pieces[1].startedAt).toBe(local(2025, 3, 30, 0, 0));
    expect(closedTotal([pieces[0]])).toBe(2 * HOUR);
    expect(closedTotal([pieces[1]])).toBe(2 * HOUR + 30 * MINUTE);
    expect(closedTotal(pieces)).toBe(4 * HOUR + 30 * MINUTE);
  });
});

describe('splitOpenSpanAt', () => {
  it('returns null for a closed span', () => {
    expect(
      splitOpenSpanAt(
        span('work', local(2025, 8, 4, 9, 0), local(2025, 8, 4, 17, 0)),
        local(2025, 8, 5, 9, 0),
      ),
    ).toBeNull();
  });

  it('returns null while the open span is still on its own day', () => {
    const open = span('work', local(2025, 8, 4, 22, 0), null);
    expect(splitOpenSpanAt(open, local(2025, 8, 4, 23, 30))).toBeNull();
    expect(splitOpenSpanAt(open, local(2025, 8, 4, 23, 59, 59, 999))).toBeNull();
  });

  it('splits once now has reached midnight exactly', () => {
    const open = span('work', local(2025, 8, 4, 22, 0), null);
    const result = splitOpenSpanAt(open, local(2025, 8, 5, 0, 0));

    expect(result).not.toBeNull();
    expect(result?.closed).toEqual([
      {
        date: '2025-08-04',
        type: 'work',
        startedAt: local(2025, 8, 4, 22, 0),
        endedAt: local(2025, 8, 5, 0, 0),
      },
    ]);
    expect(result?.reopened).toEqual({
      date: '2025-08-05',
      type: 'work',
      startedAt: local(2025, 8, 5, 0, 0),
      endedAt: null,
    });
  });

  it('closes at midnight and reopens there once now is past the boundary', () => {
    const open = span('break', local(2025, 8, 4, 23, 15), null);
    const result = splitOpenSpanAt(open, local(2025, 8, 5, 0, 30));

    expect(result?.closed).toEqual([
      {
        date: '2025-08-04',
        type: 'break',
        startedAt: local(2025, 8, 4, 23, 15),
        endedAt: local(2025, 8, 5, 0, 0),
      },
    ]);
    expect(result?.reopened.startedAt).toBe(local(2025, 8, 5, 0, 0));
    expect(result?.reopened.endedAt).toBeNull();
    expect(result?.reopened.type).toBe('break');
  });

  it('emits one closed piece per elapsed day when the app ran for days', () => {
    const open = span('work', local(2025, 8, 4, 22, 0), null);
    const result = splitOpenSpanAt(open, local(2025, 8, 6, 10, 0));

    expect(result).not.toBeNull();
    const closed = result?.closed ?? [];
    expect(closed.map((piece) => piece.date)).toEqual(['2025-08-04', '2025-08-05']);
    expectContiguous(closed);
    expect(closedTotal(closed)).toBe(26 * HOUR);
    expect(result?.reopened).toEqual({
      date: '2025-08-06',
      type: 'work',
      startedAt: local(2025, 8, 6, 0, 0),
      endedAt: null,
    });
    // The reopened piece continues exactly where the last closed one stopped.
    expect(closed[closed.length - 1].endedAt).toBe(result?.reopened.startedAt);
  });

  it('uses the real local midnight across the 23-hour day', () => {
    const open = span('work', local(2025, 3, 29, 23, 0), null);
    const result = splitOpenSpanAt(open, local(2025, 3, 30, 12, 0));

    expect(result?.closed).toEqual([
      {
        date: '2025-03-29',
        type: 'work',
        startedAt: local(2025, 3, 29, 23, 0),
        endedAt: local(2025, 3, 30, 0, 0),
      },
    ]);
    expect(result?.reopened.startedAt).toBe(local(2025, 3, 30, 0, 0));
    expect(result?.reopened.date).toBe('2025-03-30');
  });

  it('uses the real local midnight across the 25-hour day', () => {
    const open = span('work', local(2025, 10, 25, 23, 0), null);
    const result = splitOpenSpanAt(open, local(2025, 10, 26, 12, 0));

    expect(closedTotal(result?.closed ?? [])).toBe(HOUR);
    expect(result?.reopened.startedAt).toBe(local(2025, 10, 26, 0, 0));
    expect(result?.reopened.date).toBe('2025-10-26');
  });

  it('is idempotent: re-running it on the reopened piece does nothing on the same day', () => {
    const open = span('work', local(2025, 8, 4, 22, 0), null);
    const first = splitOpenSpanAt(open, local(2025, 8, 5, 0, 30));
    expect(first).not.toBeNull();

    const reopened = span('work', first?.reopened.startedAt ?? 0, null);
    expect(splitOpenSpanAt(reopened, local(2025, 8, 5, 0, 30))).toBeNull();
  });
});

/**
 * Tests for crash recovery and the idle / sleep-gap decisions.
 *
 * Every function here is pure: it turns (segment, heartbeat, now) into a description
 * or a plan, and never touches storage. The cases below therefore pin down exactly
 * which instants a plan carries, because the caller writes those verbatim.
 */

import { describe, expect, it } from 'vitest';
import {
  RECOVERY_GAP_FLOOR_MS,
  buildPendingRecovery,
  isRecoveryWorthPrompting,
  planIdle,
  planRecovery,
  planWake,
  resolveHeartbeatCloseInstant,
} from '@domain/recovery';
import type { Segment, SegmentType } from '@shared/types';

const HOUR = 3_600_000;
const MINUTE = 60_000;
const SECOND = 1_000;

function local(y: number, m: number, d: number, h = 0, min = 0, s = 0): number {
  return new Date(y, m - 1, d, h, min, s, 0).getTime();
}

/** Hours on 2025-08-04 unless a case explicitly needs another day. */
function at(h: number, min = 0, s = 0): number {
  return local(2025, 8, 4, h, min, s);
}

function segment(
  id: number,
  type: SegmentType,
  startedAt: number,
  endedAt: number | null = null,
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

describe('resolveHeartbeatCloseInstant', () => {
  const open = segment(1, 'work', at(9));

  it('uses the heartbeat when it sits inside the segment', () => {
    expect(resolveHeartbeatCloseInstant(open, at(11, 30), at(14))).toBe(at(11, 30));
  });

  it('falls back to the segment start when there is no heartbeat', () => {
    expect(resolveHeartbeatCloseInstant(open, null, at(14))).toBe(at(9));
  });

  it('pulls a future heartbeat back to now', () => {
    expect(resolveHeartbeatCloseInstant(open, at(15), at(14))).toBe(at(14));
  });

  it('pushes a heartbeat older than the segment up to the segment start', () => {
    expect(resolveHeartbeatCloseInstant(open, at(8), at(14))).toBe(at(9));
  });
});

describe('buildPendingRecovery', () => {
  it('splits the open time into recoverable and unaccounted-for', () => {
    const open = segment(1, 'work', at(9));
    const pending = buildPendingRecovery(open, at(11, 30), at(14));

    expect(pending).toEqual({
      segment: open,
      date: '2025-08-04',
      lastHeartbeatAt: at(11, 30),
      recoverableMs: 2 * HOUR + 30 * MINUTE,
      gapMs: 2 * HOUR + 30 * MINUTE,
    });
  });

  it('recovers nothing when there was never a heartbeat', () => {
    const open = segment(1, 'work', at(9));
    const pending = buildPendingRecovery(open, null, at(14));

    expect(pending.lastHeartbeatAt).toBeNull();
    expect(pending.recoverableMs).toBe(0);
    expect(pending.gapMs).toBe(5 * HOUR);
  });

  it('clamps a heartbeat from the future back to now, leaving no gap', () => {
    // A backwards clock change can leave a heartbeat that is still ahead of `now`.
    const open = segment(1, 'work', at(9));
    const pending = buildPendingRecovery(open, at(15), at(14));

    expect(pending.lastHeartbeatAt).toBe(at(15));
    expect(pending.recoverableMs).toBe(5 * HOUR);
    expect(pending.gapMs).toBe(0);
  });

  it('clamps a heartbeat older than the segment up to the segment start', () => {
    const open = segment(1, 'work', at(9));
    const pending = buildPendingRecovery(open, at(8), at(14));

    expect(pending.lastHeartbeatAt).toBe(at(8));
    expect(pending.recoverableMs).toBe(0);
    expect(pending.gapMs).toBe(5 * HOUR);
  });

  it('reports the day the segment started on, not the day the app relaunched', () => {
    const open = segment(1, 'work', local(2025, 8, 3, 22, 0));
    const pending = buildPendingRecovery(open, local(2025, 8, 3, 23, 30), local(2025, 8, 4, 9, 0));

    expect(pending.date).toBe('2025-08-03');
    expect(pending.recoverableMs).toBe(HOUR + 30 * MINUTE);
    expect(pending.gapMs).toBe(9 * HOUR + 30 * MINUTE);
  });

  it('never reports negative durations when now precedes the segment', () => {
    const open = segment(1, 'work', at(9));
    const pending = buildPendingRecovery(open, at(9, 30), at(8));

    expect(pending.recoverableMs).toBe(0);
    expect(pending.gapMs).toBe(0);
  });
});

describe('planRecovery', () => {
  const open = segment(42, 'work', at(9));
  const pending = buildPendingRecovery(open, at(11, 30), at(14));

  it('carries on timing for "resume"', () => {
    expect(planRecovery(pending, 'resume', at(14))).toEqual({ action: 'resume', segmentId: 42 });
  });

  it('deletes the segment for "discard"', () => {
    expect(planRecovery(pending, 'discard', at(14))).toEqual({ action: 'discard', segmentId: 42 });
  });

  it('closes at the heartbeat for "close-at-heartbeat"', () => {
    expect(planRecovery(pending, 'close-at-heartbeat', at(14))).toEqual({
      action: 'close',
      segmentId: 42,
      endedAt: at(11, 30),
    });
  });

  it('re-clamps a future heartbeat to the instant the plan is made', () => {
    const future = buildPendingRecovery(open, at(15), at(14));
    expect(planRecovery(future, 'close-at-heartbeat', at(14, 5))).toEqual({
      action: 'close',
      segmentId: 42,
      endedAt: at(14, 5),
    });
  });

  it('degrades "close-at-heartbeat" to discard when there is no heartbeat', () => {
    const never = buildPendingRecovery(open, null, at(14));
    expect(planRecovery(never, 'close-at-heartbeat', at(14))).toEqual({
      action: 'discard',
      segmentId: 42,
    });
  });

  it('degrades "close-at-heartbeat" to discard when the heartbeat equals the start', () => {
    const atStart = buildPendingRecovery(open, at(9), at(14));
    expect(planRecovery(atStart, 'close-at-heartbeat', at(14))).toEqual({
      action: 'discard',
      segmentId: 42,
    });
  });

  it('degrades "close-at-heartbeat" to discard when the heartbeat predates the start', () => {
    const stale = buildPendingRecovery(open, at(8), at(14));
    expect(planRecovery(stale, 'close-at-heartbeat', at(14))).toEqual({
      action: 'discard',
      segmentId: 42,
    });
  });

  it('degrades "close-at-heartbeat" to discard when now has fallen back before the start', () => {
    expect(planRecovery(pending, 'close-at-heartbeat', at(8))).toEqual({
      action: 'discard',
      segmentId: 42,
    });
  });
});

describe('isRecoveryWorthPrompting', () => {
  const open = segment(1, 'work', at(9));

  it('prompts when meaningful time can be recovered', () => {
    expect(isRecoveryWorthPrompting(buildPendingRecovery(open, at(11), at(11, 0, 1)))).toBe(true);
  });

  it('prompts when a meaningful stretch is unaccounted for', () => {
    // Nothing recoverable — no heartbeat — but hours of unexplained time.
    expect(isRecoveryWorthPrompting(buildPendingRecovery(open, null, at(14)))).toBe(true);
  });

  it('stays silent for a segment that was opened moments before the crash', () => {
    const started = at(9);
    const justOpened = segment(1, 'work', started);
    const pending = buildPendingRecovery(justOpened, started + 300, started + 800);

    expect(pending.recoverableMs).toBe(300);
    expect(pending.gapMs).toBe(500);
    expect(isRecoveryWorthPrompting(pending)).toBe(false);
  });

  it('prompts exactly at the one-second floor', () => {
    expect(RECOVERY_GAP_FLOOR_MS).toBe(SECOND);

    const started = at(9);
    const justUnder = buildPendingRecovery(
      segment(1, 'work', started),
      started + RECOVERY_GAP_FLOOR_MS - 1,
      started + RECOVERY_GAP_FLOOR_MS + RECOVERY_GAP_FLOOR_MS - 2,
    );
    expect(justUnder.recoverableMs).toBe(RECOVERY_GAP_FLOOR_MS - 1);
    expect(justUnder.gapMs).toBe(RECOVERY_GAP_FLOOR_MS - 1);
    expect(isRecoveryWorthPrompting(justUnder)).toBe(false);

    const exactlyAtFloor = buildPendingRecovery(
      segment(1, 'work', started),
      started + RECOVERY_GAP_FLOOR_MS,
      started + RECOVERY_GAP_FLOOR_MS,
    );
    expect(exactlyAtFloor.recoverableMs).toBe(RECOVERY_GAP_FLOOR_MS);
    expect(exactlyAtFloor.gapMs).toBe(0);
    expect(isRecoveryWorthPrompting(exactlyAtFloor)).toBe(true);
  });

  it('stays silent for a zero-length pending recovery', () => {
    const started = at(9);
    expect(isRecoveryWorthPrompting(buildPendingRecovery(segment(1, 'work', started), null, started))).toBe(
      false,
    );
  });
});

describe('planIdle', () => {
  const open = segment(7, 'work', at(9));

  it('leaves the segment alone for "keep"', () => {
    expect(planIdle(open, at(11), 'keep', at(12))).toEqual({ action: 'keep' });
  });

  it('trims to the moment the user went idle and restarts now for "discard"', () => {
    expect(planIdle(open, at(11), 'discard', at(12))).toEqual({
      action: 'trim',
      segmentId: 7,
      endedAt: at(11),
      resumeAt: at(12),
    });
  });

  it('keeps the segment when the whole of it was idle', () => {
    expect(planIdle(open, at(9), 'discard', at(12))).toEqual({ action: 'keep' });
    expect(planIdle(open, at(8), 'discard', at(12))).toEqual({ action: 'keep' });
  });

  it('clamps an idle start that is somehow in the future down to now', () => {
    expect(planIdle(open, at(13), 'discard', at(12))).toEqual({
      action: 'trim',
      segmentId: 7,
      endedAt: at(12),
      resumeAt: at(12),
    });
  });

  it('keeps the segment when now itself has fallen back before the start', () => {
    expect(planIdle(open, at(11), 'discard', at(8))).toEqual({ action: 'keep' });
  });

  it('ignores every other input for "keep"', () => {
    expect(planIdle(open, at(8), 'keep', at(8))).toEqual({ action: 'keep' });
  });
});

describe('planWake', () => {
  it('drops the gap entirely for "resume"', () => {
    expect(planWake(at(13), at(14), 'resume')).toEqual({
      action: 'resume-work',
      workStartsAt: at(14),
    });
  });

  it('records the gap as a break for "count-as-break"', () => {
    expect(planWake(at(13), at(14), 'count-as-break')).toEqual({
      action: 'record-break',
      breakStartedAt: at(13),
      breakEndedAt: at(14),
      workStartsAt: at(14),
    });
  });

  it('refuses to record a zero-length break', () => {
    expect(planWake(at(13), at(13), 'count-as-break')).toEqual({
      action: 'resume-work',
      workStartsAt: at(13),
    });
  });

  it('refuses to record a negative gap, whatever the choice', () => {
    expect(planWake(at(14), at(13), 'count-as-break')).toEqual({
      action: 'resume-work',
      workStartsAt: at(13),
    });
    expect(planWake(at(14), at(13), 'resume')).toEqual({
      action: 'resume-work',
      workStartsAt: at(13),
    });
  });

  it('leaves a gap that spans midnight whole — splitting belongs to the caller', () => {
    expect(planWake(local(2025, 8, 4, 23, 0), local(2025, 8, 5, 7, 0), 'count-as-break')).toEqual({
      action: 'record-break',
      breakStartedAt: local(2025, 8, 4, 23, 0),
      breakEndedAt: local(2025, 8, 5, 7, 0),
      workStartsAt: local(2025, 8, 5, 7, 0),
    });
  });
});

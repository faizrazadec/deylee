/**
 * Crash / unclean-quit recovery.
 *
 * While the timer runs, the main process writes a heartbeat timestamp every 30s.
 * If the app dies, the segment stays open and the heartbeat marks the last instant
 * we know the machine was actually being used. On the next launch we surface that
 * to the user and let them decide.
 *
 * This module is pure: it turns (open segment, heartbeat, now) into a description
 * of the choice, and a choice into a plan. Persisting the plan is the caller's job,
 * which keeps the decision logic testable without a database.
 */

import { dateKeyOf } from '../shared/time';
import type { EpochMs, PendingRecovery, RecoveryChoice, Segment } from '../shared/types';

/** How long a gap must be before it is worth mentioning to the user. */
export const RECOVERY_GAP_FLOOR_MS = 1_000;

/**
 * Describe an open segment found at startup.
 *
 * `recoverableMs` is what `close-at-heartbeat` would keep; `gapMs` is the time
 * between the last heartbeat and now, which nobody can account for.
 */
export function buildPendingRecovery(
  segment: Segment,
  lastHeartbeatAt: EpochMs | null,
  now: EpochMs = Date.now(),
): PendingRecovery {
  const closeAt = resolveHeartbeatCloseInstant(segment, lastHeartbeatAt, now);
  return {
    segment,
    date: dateKeyOf(segment.startedAt),
    lastHeartbeatAt,
    recoverableMs: Math.max(0, closeAt - segment.startedAt),
    gapMs: Math.max(0, now - closeAt),
  };
}

/**
 * The instant `close-at-heartbeat` would use.
 *
 * Clamped into `[segment.startedAt, now]`: a missing heartbeat falls back to the
 * segment start (keeping nothing), and a heartbeat from the future — possible after
 * a backwards clock change — is pulled back to now.
 */
export function resolveHeartbeatCloseInstant(
  segment: Segment,
  lastHeartbeatAt: EpochMs | null,
  now: EpochMs = Date.now(),
): EpochMs {
  if (lastHeartbeatAt === null) return segment.startedAt;
  return Math.min(Math.max(lastHeartbeatAt, segment.startedAt), now);
}

export type RecoveryPlan =
  /** Leave the segment open and carry on timing from where it was. */
  | { action: 'resume'; segmentId: number }
  /** Close it at the heartbeat, keeping the time up to that point. */
  | { action: 'close'; segmentId: number; endedAt: EpochMs }
  /** Delete it entirely; the time is not counted. */
  | { action: 'discard'; segmentId: number };

/**
 * Turn the user's choice into a concrete plan.
 *
 * `close-at-heartbeat` degrades to `discard` when it would produce a zero-length
 * segment, because storing an empty segment would show up as a phantom row in the
 * day list.
 */
export function planRecovery(
  pending: PendingRecovery,
  choice: RecoveryChoice,
  now: EpochMs = Date.now(),
): RecoveryPlan {
  const segmentId = pending.segment.id;

  switch (choice) {
    case 'resume':
      return { action: 'resume', segmentId };

    case 'discard':
      return { action: 'discard', segmentId };

    case 'close-at-heartbeat': {
      const endedAt = resolveHeartbeatCloseInstant(
        pending.segment,
        pending.lastHeartbeatAt,
        now,
      );
      if (endedAt <= pending.segment.startedAt) {
        return { action: 'discard', segmentId };
      }
      return { action: 'close', segmentId, endedAt };
    }
  }
}

/**
 * Whether an open segment found at startup is worth prompting about at all.
 *
 * A segment opened seconds before the app died — for example a start immediately
 * followed by a crash — carries no meaningful time, so it is silently discarded
 * rather than interrupting the user with a dialog.
 */
export function isRecoveryWorthPrompting(pending: PendingRecovery): boolean {
  return pending.recoverableMs >= RECOVERY_GAP_FLOOR_MS || pending.gapMs >= RECOVERY_GAP_FLOOR_MS;
}

/* -------------------------------------------------------------------------- */
/* Idle time                                                                   */
/* -------------------------------------------------------------------------- */

/**
 * Applying an idle decision to the open work segment.
 *
 * `keep` leaves the segment untouched. `discard` closes it at the instant the user
 * went idle and opens a fresh segment now, so the idle stretch is simply absent
 * from the record rather than being recorded as a break.
 */
export type IdlePlan =
  | { action: 'keep' }
  | { action: 'trim'; segmentId: number; endedAt: EpochMs; resumeAt: EpochMs };

export function planIdle(
  segment: Segment,
  idleStartedAt: EpochMs,
  choice: 'keep' | 'discard',
  now: EpochMs = Date.now(),
): IdlePlan {
  if (choice === 'keep') return { action: 'keep' };

  const endedAt = Math.min(Math.max(idleStartedAt, segment.startedAt), now);
  if (endedAt <= segment.startedAt) {
    // The whole segment was idle; trimming it to nothing is not representable, so
    // keep the segment and let the user delete it manually if they want to.
    return { action: 'keep' };
  }
  return { action: 'trim', segmentId: segment.id, endedAt, resumeAt: now };
}

/* -------------------------------------------------------------------------- */
/* Sleep / lock gaps                                                           */
/* -------------------------------------------------------------------------- */

/**
 * Applying a wake decision to a segment that was auto-paused on sleep or lock.
 *
 * The work segment was already closed at `gapStartedAt` when the machine went away.
 * On wake the user chooses what the gap itself was:
 *  - `resume`        — the gap is not recorded at all; a new work segment starts now.
 *  - `count-as-break`— the gap becomes a break segment, then work starts now.
 */
export type WakePlan =
  | { action: 'resume-work'; workStartsAt: EpochMs }
  | {
      action: 'record-break';
      breakStartedAt: EpochMs;
      breakEndedAt: EpochMs;
      workStartsAt: EpochMs;
    };

export function planWake(
  gapStartedAt: EpochMs,
  gapEndedAt: EpochMs,
  choice: 'resume' | 'count-as-break',
): WakePlan {
  if (choice === 'resume' || gapEndedAt <= gapStartedAt) {
    return { action: 'resume-work', workStartsAt: gapEndedAt };
  }
  return {
    action: 'record-break',
    breakStartedAt: gapStartedAt,
    breakEndedAt: gapEndedAt,
    workStartsAt: gapEndedAt,
  };
}

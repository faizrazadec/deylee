/**
 * The timer state machine, and the only writer of timer segments.
 *
 * Nothing about the current state is persisted: `TimerState` is derived from the one
 * open segment and today's day row every time it is read. That is what makes the app
 * crash-safe — a `kill -9` cannot leave a status column lying about what happened,
 * because there is no status column, only rows describing time that really elapsed.
 *
 * Pause/resume boundaries share an instant: the closing segment ends at exactly the
 * moment the next one begins. Intervals are half-open (`@domain/overlap`), so that is
 * a touch, not an overlap, and no millisecond is ever lost or double-counted.
 *
 * Every transition that cannot legally happen from the current state is a no-op that
 * returns the current snapshot. The UI disables those buttons, but IPC, the tray menu
 * and the recovery prompts can all race each other, and throwing would be worse.
 */

import { hoursToMinutes, dayTotals, sumWithinDay } from '@domain/duration';
import { splitAtMidnight, splitOpenSpanAt } from '@domain/midnight';
import type { IdlePlan, RecoveryPlan, WakePlan } from '@domain/recovery';
import type { Repository } from '@main/db/repository';
import type { PreferencesStore } from '@main/store/preferences';
import { dateKeyOf } from '@shared/time';
import type { EpochMs, SegmentType, TimerSnapshot, TimerState } from '@shared/types';

export interface TimerServiceDeps {
  repo: Repository;
  prefs: PreferencesStore;
  /** Injectable for tests; defaults to `Date.now`. */
  now?: () => EpochMs;
}

type SnapshotListener = (snapshot: TimerSnapshot) => void;

export class TimerService {
  private readonly repo: Repository;
  private readonly prefs: PreferencesStore;
  private readonly clock: () => EpochMs;
  private readonly listeners = new Set<SnapshotListener>();

  constructor(deps: TimerServiceDeps) {
    this.repo = deps.repo;
    this.prefs = deps.prefs;
    this.clock = deps.now ?? Date.now;
  }

  /* ---------------------------------------------------------------------- */
  /* Reads                                                                   */
  /* ---------------------------------------------------------------------- */

  getSnapshot(now: EpochMs = this.clock()): TimerSnapshot {
    const date = dateKeyOf(now);
    const day = this.repo.findDay(date);
    const open = this.repo.findOpenSegment();
    const segments = day === null ? [] : this.repo.listSegments(day.id);

    // Only closed segments are summed here; the open one is sent along untouched so
    // renderers can recompute the live value on their own tick (`liveTotals`).
    const closed = segments.filter((segment) => segment.endedAt !== null);
    const totals = dayTotals(segments, date, now);

    const state: TimerState =
      open !== null
        ? open.type === 'work'
          ? 'RUNNING'
          : 'PAUSED'
        : day !== null && day.endedAt !== null
          ? 'ENDED'
          : 'IDLE';

    return {
      state,
      date,
      dayId: day === null ? null : day.id,
      closedWorkedMs: sumWithinDay(closed, 'work', date, now),
      closedBreakMs: sumWithinDay(closed, 'break', date, now),
      openSegment: open,
      firstStartAt: totals.firstStartAt,
      lastEndAt: totals.lastEndAt,
      // The day row's stamped target wins so that the panel and the History window
      // never disagree about whether a day met its goal; a changed preference applies
      // from the next day on.
      targetMinutes: day === null ? this.currentTargetMinutes() : day.targetMinutes,
      asOf: now,
    };
  }

  /* ---------------------------------------------------------------------- */
  /* Transitions                                                             */
  /* ---------------------------------------------------------------------- */

  /** IDLE or ENDED → RUNNING. Restarting after End Day un-finalises the same day. */
  start(): TimerSnapshot {
    const now = this.clock();
    // IDLE and ENDED are exactly the states with no open segment anywhere.
    if (this.repo.findOpenSegment() !== null) return this.getSnapshot(now);

    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      this.openAt('work', now, targetMinutes, now);
    });
    return this.emit();
  }

  /** RUNNING → PAUSED. */
  pause(): TimerSnapshot {
    return this.switchOpenSegment('work', 'break');
  }

  /** PAUSED → RUNNING. */
  resume(): TimerSnapshot {
    return this.switchOpenSegment('break', 'work');
  }

  /** RUNNING or PAUSED → ENDED. */
  endDay(): TimerSnapshot {
    const now = this.clock();
    const open = this.repo.findOpenSegment();
    if (open === null) return this.getSnapshot(now);

    const at = Math.max(now, open.startedAt);
    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      this.repo.closeSegmentSplitting(open.id, at, targetMinutes, now);
      // The day that is finalised is the one `at` falls in, which is also the day the
      // final piece of a midnight-crossing segment was attributed to.
      const day = this.repo.getOrCreateDay(dateKeyOf(at), targetMinutes, now);
      this.repo.setDayEnded(day.id, at);
    });
    return this.emit();
  }

  /* ---------------------------------------------------------------------- */
  /* Plans from @domain/recovery                                             */
  /* ---------------------------------------------------------------------- */

  applyRecovery(plan: RecoveryPlan): TimerSnapshot {
    const now = this.clock();
    const segment = this.repo.getSegment(plan.segmentId);
    if (segment === null) return this.getSnapshot(now);

    switch (plan.action) {
      case 'resume':
        // The segment is already open and already counting — there is nothing to write.
        return this.getSnapshot(now);

      case 'close': {
        if (segment.endedAt !== null) return this.getSnapshot(now);
        const at = Math.max(plan.endedAt, segment.startedAt);
        const targetMinutes = this.currentTargetMinutes();
        this.repo.transaction(() => {
          // A zero-length close would leave a phantom row in the day list; there is
          // nothing worth keeping, so the segment goes instead.
          if (at <= segment.startedAt) this.repo.deleteSegment(segment.id);
          else this.repo.closeSegmentSplitting(segment.id, at, targetMinutes, now);
        });
        return this.emit();
      }

      case 'discard':
        this.repo.transaction(() => {
          this.repo.deleteSegment(segment.id);
        });
        return this.emit();
    }
  }

  applyIdle(plan: IdlePlan): TimerSnapshot {
    const now = this.clock();
    if (plan.action === 'keep') return this.getSnapshot(now);

    const segment = this.repo.getSegment(plan.segmentId);
    if (segment === null || segment.endedAt !== null) return this.getSnapshot(now);

    // Trim to the instant the user went idle, then pick up again now, so the idle
    // stretch is absent from the record rather than recorded as anything.
    const endedAt = Math.min(Math.max(plan.endedAt, segment.startedAt), plan.resumeAt);
    if (endedAt <= segment.startedAt) return this.getSnapshot(now);

    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      this.repo.closeSegmentSplitting(segment.id, endedAt, targetMinutes, now);
      this.openAt(segment.type, plan.resumeAt, targetMinutes, now);
    });
    return this.emit();
  }

  /** Closes the open work segment at `at` because the machine slept or locked. */
  suspendAt(at: EpochMs): void {
    const now = this.clock();
    const open = this.repo.findOpenSegment();
    // A break already accounts for the gap, so only work is cut short here.
    if (open === null || open.type !== 'work') return;

    const endedAt = Math.min(Math.max(at, open.startedAt), now);
    // Nothing to keep and nothing to close — leave the segment running rather than
    // storing an empty row; the wake handler will find it still open and stand down.
    if (endedAt <= open.startedAt) return;

    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      this.repo.closeSegmentSplitting(open.id, endedAt, targetMinutes, now);
    });
    this.emit();
  }

  applyWake(plan: WakePlan): TimerSnapshot {
    const now = this.clock();
    // The suspend never closed anything (a break was open, or the gap was empty), so
    // the timer is already in the right state and a second open segment would corrupt it.
    if (this.repo.findOpenSegment() !== null) return this.getSnapshot(now);

    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      if (plan.action === 'record-break') {
        this.insertClosedSpan('break', plan.breakStartedAt, plan.breakEndedAt, targetMinutes, now);
      }
      this.openAt('work', plan.workStartsAt, targetMinutes, now);
    });
    return this.emit();
  }

  /* ---------------------------------------------------------------------- */
  /* Midnight                                                                */
  /* ---------------------------------------------------------------------- */

  /**
   * Splits the open segment when it has run past local midnight, so each calendar day
   * owns its own rows even if nobody touched the app. Called on a short interval, so
   * the no-work path stays two indexed reads.
   */
  rollOverMidnight(now: EpochMs = this.clock()): TimerSnapshot {
    const open = this.repo.findOpenSegment();
    if (open === null) return this.getSnapshot(now);

    const split = splitOpenSpanAt(open, now);
    if (split === null) return this.getSnapshot(now);

    const boundary = split.reopened.startedAt;
    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      // The repository owns row identity when a close spans several days: the original
      // row becomes the first piece and the rest are inserted against their own days.
      this.repo.closeSegmentSplitting(open.id, boundary, targetMinutes, now);
      this.openAt(split.reopened.type, boundary, targetMinutes, now);
    });
    return this.emit();
  }

  /* ---------------------------------------------------------------------- */
  /* Listeners                                                               */
  /* ---------------------------------------------------------------------- */

  onSnapshot(listener: SnapshotListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  emit(): TimerSnapshot {
    const snapshot = this.getSnapshot();
    // Copied so a listener that unsubscribes itself cannot disturb the iteration, and
    // isolated so one failing listener cannot stop the tray or the windows updating.
    for (const listener of [...this.listeners]) {
      try {
        listener(snapshot);
      } catch (error) {
        console.error('[timer] snapshot listener failed', error);
      }
    }
    return snapshot;
  }

  /* ---------------------------------------------------------------------- */
  /* Internals                                                               */
  /* ---------------------------------------------------------------------- */

  /** The target stamped onto a day row when it is created. */
  private currentTargetMinutes(): number {
    return hoursToMinutes(this.prefs.get('dailyTargetHours'));
  }

  /**
   * Closes the open segment of type `from` and opens one of type `to` at the same
   * instant. Wrong-state calls (nothing open, or the other type open) are no-ops.
   */
  private switchOpenSegment(from: SegmentType, to: SegmentType): TimerSnapshot {
    const now = this.clock();
    const open = this.repo.findOpenSegment();
    if (open === null || open.type !== from) return this.getSnapshot(now);

    // Guards against a backwards clock jump producing a reversed segment.
    const at = Math.max(now, open.startedAt);
    const targetMinutes = this.currentTargetMinutes();
    this.repo.transaction(() => {
      this.repo.closeSegmentSplitting(open.id, at, targetMinutes, now);
      this.openAt(to, at, targetMinutes, now);
    });
    return this.emit();
  }

  /** Opens a segment on the day containing `at`, un-finalising that day if needed. */
  private openAt(type: SegmentType, at: EpochMs, targetMinutes: number, now: EpochMs): void {
    const day = this.repo.getOrCreateDay(dateKeyOf(at), targetMinutes, now);
    // A day with time running on it is by definition not finished.
    if (day.endedAt !== null) this.repo.setDayEnded(day.id, null);
    this.repo.insertSegment({ dayId: day.id, type, startedAt: at, endedAt: null }, now);
  }

  /** Stores an already-finished span as one row per local day it covers. */
  private insertClosedSpan(
    type: SegmentType,
    startedAt: EpochMs,
    endedAt: EpochMs,
    targetMinutes: number,
    now: EpochMs,
  ): void {
    for (const piece of splitAtMidnight({ type, startedAt, endedAt })) {
      if (piece.endedAt === null || piece.endedAt <= piece.startedAt) continue;
      const day = this.repo.getOrCreateDay(piece.date, targetMinutes, now);
      this.repo.insertSegment(
        { dayId: day.id, type, startedAt: piece.startedAt, endedAt: piece.endedAt },
        now,
      );
    }
  }
}

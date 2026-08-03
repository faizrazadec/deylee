/**
 * System-idle detection.
 *
 * How long the *machine* has gone without input is the only portable way to notice
 * that the user walked away while the timer kept counting. Reading it belongs to the
 * platform, because on Linux the obvious source lies: Chromium latches "not available"
 * the first time a confined app is refused an idle watch and answers 0 for the rest of
 * the process's life, which is indistinguishable from a user who never left.
 *
 * Detection is edge-triggered: one report per idle stretch. A level-triggered check
 * would raise a fresh prompt on every poll for as long as the user stays away, so
 * they would come back to a pile of identical prompts. The monitor re-arms only once
 * the idle time falls back below the threshold, which is the signal that the user
 * actually touched the machine again.
 */

import { MS_PER_MINUTE } from '@shared/time';
import type { EpochMs } from '@shared/types';
import type { PreferencesStore } from '@main/store/preferences';

/**
 * Fine enough that the reported idle start is accurate to a quarter minute, coarse
 * enough to be free — the threshold is measured in minutes, so polling faster buys
 * nothing.
 */
export const IDLE_POLL_INTERVAL_MS = 15_000;

export interface IdleMonitorDeps {
  prefs: PreferencesStore;
  /** Milliseconds since the last input, or null when this session cannot say. */
  readIdleMs: () => Promise<number | null>;
  onIdleDetected: (idleStartedAt: EpochMs, idleMs: EpochMs) => void;
}

export class IdleMonitor {
  private readonly prefs: PreferencesStore;
  private readonly readIdleMs: () => Promise<number | null>;
  private readonly onIdleDetected: (idleStartedAt: EpochMs, idleMs: EpochMs) => void;

  private timer: ReturnType<typeof setInterval> | null = null;
  private running = false;
  /** True once the current idle stretch has been reported; cleared when the user returns. */
  private reported = false;
  /** Guards against a slow read overlapping the next tick. */
  private polling = false;

  constructor(deps: IdleMonitorDeps) {
    this.prefs = deps.prefs;
    this.readIdleMs = deps.readIdleMs;
    this.onIdleDetected = deps.onIdleDetected;
  }

  start(): void {
    if (this.timer !== null) return;
    this.timer = setInterval(() => {
      void this.poll();
    }, IDLE_POLL_INTERVAL_MS);
  }

  stop(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.reported = false;
  }

  /** Call whenever the timer state changes; monitoring only runs while RUNNING. */
  setRunning(running: boolean): void {
    this.running = running;
    // Leaving RUNNING ends the stretch either way: any idleness in flight belonged to
    // a work segment that is now closed, so the next run must start armed.
    this.reported = false;
  }

  private async poll(): Promise<void> {
    if (this.polling) return;
    if (!this.running) return;
    if (!this.prefs.get('idleDetectionEnabled')) return;

    this.polling = true;
    try {
      const thresholdMs = this.prefs.get('idleThresholdMinutes') * MS_PER_MINUTE;
      const idleMs = await this.readIdleMs();
      // The session cannot report idleness. Staying armed is the safe answer: a false
      // "you were away" costs the user a prompt about time they were present for.
      if (idleMs === null) return;

      // Re-checked after the await: the timer may have stopped, or the preference been
      // turned off, while the read was in flight.
      if (!this.running) return;
      if (!this.prefs.get('idleDetectionEnabled')) return;

      if (idleMs < thresholdMs) {
        this.reported = false;
        return;
      }
      if (this.reported) return;

      this.reported = true;
      // The idle *start* is what the user needs to decide about, and it is only ever
      // derivable by subtracting: the OS reports a duration, not an instant.
      this.onIdleDetected(Date.now() - idleMs, idleMs);
    } finally {
      this.polling = false;
    }
  }
}

/**
 * System-idle detection.
 *
 * `powerMonitor.getSystemIdleTime()` reports how long the *machine* has gone without
 * input, in seconds. Polling it is the only portable way to notice that the user
 * walked away while the timer kept counting.
 *
 * Detection is edge-triggered: one report per idle stretch. A level-triggered check
 * would raise a fresh prompt on every poll for as long as the user stays away, so
 * they would come back to a pile of identical prompts. The monitor re-arms only once
 * the idle time falls back below the threshold, which is the signal that the user
 * actually touched the machine again.
 */

import { powerMonitor } from 'electron';

import { MS_PER_MINUTE, MS_PER_SECOND } from '@shared/time';
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
  onIdleDetected: (idleStartedAt: EpochMs, idleMs: EpochMs) => void;
}

export class IdleMonitor {
  private readonly prefs: PreferencesStore;
  private readonly onIdleDetected: (idleStartedAt: EpochMs, idleMs: EpochMs) => void;

  private timer: ReturnType<typeof setInterval> | null = null;
  private running = false;
  /** True once the current idle stretch has been reported; cleared when the user returns. */
  private reported = false;

  constructor(deps: IdleMonitorDeps) {
    this.prefs = deps.prefs;
    this.onIdleDetected = deps.onIdleDetected;
  }

  start(): void {
    if (this.timer !== null) return;
    this.timer = setInterval(() => {
      this.poll();
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

  private poll(): void {
    if (!this.running) return;
    if (!this.prefs.get('idleDetectionEnabled')) return;

    const thresholdMs = this.prefs.get('idleThresholdMinutes') * MS_PER_MINUTE;
    const idleMs = powerMonitor.getSystemIdleTime() * MS_PER_SECOND;

    if (idleMs < thresholdMs) {
      this.reported = false;
      return;
    }
    if (this.reported) return;

    this.reported = true;
    // The idle *start* is what the user needs to decide about, and it is only ever
    // derivable by subtracting: the OS reports a duration, not an instant.
    this.onIdleDetected(Date.now() - idleMs, idleMs);
  }
}

/**
 * Sleep / lock gap tracking.
 *
 * The machine going away is reported as an *away* instant, and its return as a closed
 * gap. Desktops do not fire these events cleanly in pairs: locking the screen and then
 * suspending emits `lock-screen` **and** `suspend`, and waking emits `resume` **and**
 * `unlock-screen`. Treating each event as its own gap would count the same absence
 * twice and leave a stale away instant behind forever.
 *
 * So one gap is open at a time: the first away event opens it (keeping the earliest
 * instant, which is the one the user actually stopped working at), later away events
 * fold into it, and the first return event closes it. A return with nothing recorded —
 * an unlock after a lock the user chose not to auto-pause on — is ignored.
 *
 * None of those events is guaranteed to arrive. `lock-screen` never fires on Linux at
 * all, and inside a strict snap the app cannot reach logind, so `suspend` and `resume`
 * go missing too. A wall-clock watchdog covers that: a timer due ten seconds ago that
 * fires an hour late is a sleep nobody announced. It needs no permission and behaves
 * the same everywhere, and it is deduplicated against the real events so a machine
 * that does report them never counts one absence twice.
 */

import { powerMonitor } from 'electron';

import type { EpochMs, WakeReason } from '@shared/types';
import type { PreferencesStore } from '@main/store/preferences';

/**
 * How often the wall-clock watchdog looks for a jump.
 *
 * Frequent enough that the gap it reports starts within a tick of the real sleep,
 * cheap enough to ignore: one `Date.now()` comparison.
 */
export const SLEEP_WATCHDOG_INTERVAL_MS = 10_000;

/**
 * How far the clock must jump past the interval before it counts as an absence.
 *
 * A loaded machine can delay a timer by a second or two, and a tick that merely ran
 * late is not a sleep. Well under the shortest nap anyone takes, comfortably above
 * ordinary scheduler jitter.
 */
export const SLEEP_DRIFT_THRESHOLD_MS = 60_000;

interface AwayMark {
  at: EpochMs;
  reason: WakeReason;
}

export interface PowerMonitorServiceDeps {
  prefs: PreferencesStore;
  onAway: (at: EpochMs, reason: WakeReason) => void;
  onBack: (awayAt: EpochMs, backAt: EpochMs, reason: WakeReason) => void;
}

export class PowerMonitorService {
  private readonly prefs: PreferencesStore;
  private readonly onAway: (at: EpochMs, reason: WakeReason) => void;
  private readonly onBack: (awayAt: EpochMs, backAt: EpochMs, reason: WakeReason) => void;

  private away: AwayMark | null = null;
  private started = false;

  private watchdog: ReturnType<typeof setInterval> | null = null;
  /** When the watchdog last ran, so the next tick can measure how long it really took. */
  private lastTickAt: EpochMs = 0;
  /**
   * When a gap last closed, so a `resume` that already reported an absence is not
   * reported a second time by the watchdog noticing the same jump.
   *
   * Null rather than 0 for "never": 0 is a real instant, and comparing it against a
   * tick that also happens to be 0 would read as "already reported" when nothing has
   * been.
   */
  private lastGapClosedAt: EpochMs | null = null;

  // Held as fields so `removeListener` gets the exact same references back.
  private readonly handleSuspend = (): void => {
    this.markAway('suspend');
  };
  private readonly handleResume = (): void => {
    this.markBack();
  };
  private readonly handleLockScreen = (): void => {
    this.markAway('lock-screen');
  };
  private readonly handleUnlockScreen = (): void => {
    this.markBack();
  };

  constructor(deps: PowerMonitorServiceDeps) {
    this.prefs = deps.prefs;
    this.onAway = deps.onAway;
    this.onBack = deps.onBack;
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    powerMonitor.on('suspend', this.handleSuspend);
    powerMonitor.on('resume', this.handleResume);
    powerMonitor.on('lock-screen', this.handleLockScreen);
    powerMonitor.on('unlock-screen', this.handleUnlockScreen);

    this.lastTickAt = Date.now();
    this.watchdog = setInterval(() => {
      this.checkForClockJump();
    }, SLEEP_WATCHDOG_INTERVAL_MS);
  }

  stop(): void {
    if (!this.started) return;
    this.started = false;
    powerMonitor.removeListener('suspend', this.handleSuspend);
    powerMonitor.removeListener('resume', this.handleResume);
    powerMonitor.removeListener('lock-screen', this.handleLockScreen);
    powerMonitor.removeListener('unlock-screen', this.handleUnlockScreen);

    if (this.watchdog !== null) {
      clearInterval(this.watchdog);
      this.watchdog = null;
    }
    // Drop the pending gap: nothing will be listening to close it.
    this.away = null;
  }

  /**
   * Notices a sleep the OS never announced.
   *
   * `suspend` and `resume` are not guaranteed. Inside a strict snap the app cannot
   * reach logind at all, and even unconfined they are missed often enough to matter:
   * without this, a laptop closed at lunch comes back having "worked" through it,
   * which is the one number Dayly exists to get right.
   *
   * A timer that should have fired ten seconds ago and fired an hour ago is the
   * evidence — no permission required, and it works identically on every platform.
   * The interval before the jump is the absence: `lastTickAt` is the last moment the
   * process was demonstrably awake.
   */
  private checkForClockJump(): void {
    const now = Date.now();
    const expected = this.lastTickAt + SLEEP_WATCHDOG_INTERVAL_MS;
    const previousTickAt = this.lastTickAt;
    this.lastTickAt = now;

    if (now - expected < SLEEP_DRIFT_THRESHOLD_MS) return;
    // `suspend` fired and `resume` has not: the gap is already open and its instant is
    // more accurate than ours. Let the real event close it.
    if (this.away !== null) return;
    // A suspend/resume pair already reported this same absence. Anything that closed
    // during the window we just slept through is that pair, not an earlier one.
    if (this.lastGapClosedAt !== null && this.lastGapClosedAt >= previousTickAt) return;

    if (!this.prefs.get('autoPauseOnSleep')) return;

    this.lastGapClosedAt = now;
    this.onAway(previousTickAt, 'suspend');
    this.onBack(previousTickAt, now, 'suspend');
  }

  private markAway(reason: WakeReason): void {
    if (!this.autoPauseEnabled(reason)) return;
    // A gap is already open (lock, then suspend): keep its earlier instant.
    if (this.away !== null) return;

    const at = Date.now();
    this.away = { at, reason };
    this.onAway(at, reason);
  }

  private markBack(): void {
    const away = this.away;
    if (away === null) return;

    const backAt = Date.now();
    this.away = null;
    // Recorded so the watchdog does not report the same absence again when it notices
    // the clock jumped across this very sleep.
    this.lastGapClosedAt = backAt;
    // The reason is the one that opened the gap, not the one that closed it, so the
    // prompt the user sees matches the pause they were told about.
    this.onBack(away.at, backAt, away.reason);
  }

  private autoPauseEnabled(reason: WakeReason): boolean {
    return reason === 'suspend'
      ? this.prefs.get('autoPauseOnSleep')
      : this.prefs.get('autoPauseOnLock');
  }
}

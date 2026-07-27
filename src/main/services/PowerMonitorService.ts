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
 */

import { powerMonitor } from 'electron';

import type { EpochMs, WakeReason } from '@shared/types';
import type { PreferencesStore } from '@main/store/preferences';

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
  }

  stop(): void {
    if (!this.started) return;
    this.started = false;
    powerMonitor.removeListener('suspend', this.handleSuspend);
    powerMonitor.removeListener('resume', this.handleResume);
    powerMonitor.removeListener('lock-screen', this.handleLockScreen);
    powerMonitor.removeListener('unlock-screen', this.handleUnlockScreen);
    // Drop the pending gap: nothing will be listening to close it.
    this.away = null;
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

    this.away = null;
    // The reason is the one that opened the gap, not the one that closed it, so the
    // prompt the user sees matches the pause they were told about.
    this.onBack(away.at, Date.now(), away.reason);
  }

  private autoPauseEnabled(reason: WakeReason): boolean {
    return reason === 'suspend'
      ? this.prefs.get('autoPauseOnSleep')
      : this.prefs.get('autoPauseOnLock');
  }
}

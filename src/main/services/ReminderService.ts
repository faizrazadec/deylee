/**
 * The "you are still tracking" reminder.
 *
 * A minute tick rather than a single `setTimeout` at the target time: a timeout
 * scheduled hours ahead does not survive machine sleep or a clock change, whereas
 * re-reading the wall clock every minute always lands on the right day.
 *
 * The last fired date is the whole memory of the feature. It makes the reminder
 * once-a-day, and it is what stops a re-fire when the user moves the reminder time
 * earlier in the settings after it already went off today.
 */

import { dateKeyOf } from '@shared/time';
import type { DateKey } from '@shared/types';
import type { PreferencesStore } from '@main/store/preferences';

export const REMINDER_CHECK_INTERVAL_MS = 60_000;

export interface ReminderServiceDeps {
  prefs: PreferencesStore;
  isRunning: () => boolean;
  onRemind: () => void;
}

export class ReminderService {
  private readonly prefs: PreferencesStore;
  private readonly isRunning: () => boolean;
  private readonly onRemind: () => void;

  private timer: ReturnType<typeof setInterval> | null = null;
  private lastFiredOn: DateKey | null = null;

  constructor(deps: ReminderServiceDeps) {
    this.prefs = deps.prefs;
    this.isRunning = deps.isRunning;
    this.onRemind = deps.onRemind;
  }

  start(): void {
    if (this.timer !== null) return;
    this.timer = setInterval(() => {
      this.check();
    }, REMINDER_CHECK_INTERVAL_MS);
  }

  stop(): void {
    if (this.timer === null) return;
    clearInterval(this.timer);
    this.timer = null;
    // `lastFiredOn` deliberately survives: a stop/start cycle is not a new day.
  }

  private check(): void {
    if (!this.prefs.get('reminderEnabled')) return;
    if (!this.isRunning()) return;

    const now = Date.now();
    const today = dateKeyOf(now);
    if (this.lastFiredOn === today) return;

    const clock = new Date(now);
    const minutesNow = clock.getHours() * 60 + clock.getMinutes();
    const minutesDue = this.prefs.get('reminderHour') * 60 + this.prefs.get('reminderMinute');
    if (minutesNow < minutesDue) return;

    // Marked before the callback so a throwing listener cannot cause a re-fire loop.
    this.lastFiredOn = today;
    this.onRemind();
  }
}

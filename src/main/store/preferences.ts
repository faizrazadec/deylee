/**
 * User preferences, persisted by `electron-store`.
 *
 * The store file is user-editable JSON that also survives app downgrades, so nothing
 * read back from it can be trusted: every value is validated and clamped on the way
 * in *and* on the way out. A key whose stored value is missing or the wrong shape
 * falls back to its default individually, so one bad field never costs the user the
 * rest of their settings.
 */

import Store from 'electron-store';
import type { MiniWindowPosition, Preferences } from '@shared/types';

export const DEFAULT_PREFERENCES: Preferences = {
  launchAtLogin: false,
  showMiniWindow: false,

  idleDetectionEnabled: true,
  idleThresholdMinutes: 10,

  autoPauseOnSleep: true,
  // Off by default: a screen lock during a call or a screensaver is not a break.
  autoPauseOnLock: false,

  dailyTargetHours: 8,

  reminderEnabled: false,
  reminderHour: 17,
  reminderMinute: 30,

  theme: 'system',
  weekStartsOn: 1,

  miniWindowPositions: {},

  trayFallbackNoticeShown: false,

  // On by default: a tracker nobody can patch is a worse trade than one poll of a
  // public feed. It is a single preference away from a completely offline app, and
  // nothing is ever downloaded without the user asking for it.
  updateCheckEnabled: true,
};

const IDLE_THRESHOLD_MIN_MINUTES = 1;
const IDLE_THRESHOLD_MAX_MINUTES = 240;
const DAILY_TARGET_MAX_HOURS = 24;

type PreferencesListener = (prefs: Preferences) => void;

/* -------------------------------------------------------------------------- */
/* Value coercion                                                              */
/* -------------------------------------------------------------------------- */

/** Narrows to a plain object. Arrays are rejected — no preference is one. */
function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

function asBoolean(value: unknown, fallback: boolean): boolean {
  return typeof value === 'boolean' ? value : fallback;
}

/** Clamps into `[min, max]`. A non-number, `NaN` or `Infinity` takes the default. */
function asNumberInRange(value: unknown, min: number, max: number, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, value));
}

function asIntegerInRange(value: unknown, min: number, max: number, fallback: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.round(value)));
}

function asTheme(value: unknown, fallback: Preferences['theme']): Preferences['theme'] {
  if (value === 'system' || value === 'light' || value === 'dark') return value;
  return fallback;
}

function asWeekStart(value: unknown, fallback: Preferences['weekStartsOn']): Preferences['weekStartsOn'] {
  if (typeof value !== 'number' || !Number.isFinite(value)) return fallback;
  return Math.round(value) >= 1 ? 1 : 0;
}

/**
 * Keeps only the entries that are a usable point. Coordinates are rounded because
 * Electron window bounds are integers, and a malformed entry is dropped rather than
 * poisoning the whole map — the window simply falls back to its default placement.
 */
function asPositions(
  value: unknown,
  fallback: Record<string, MiniWindowPosition>,
): Record<string, MiniWindowPosition> {
  const record = asRecord(value);
  if (record === null) return { ...fallback };

  const out: Record<string, MiniWindowPosition> = {};
  for (const [displayId, entry] of Object.entries(record)) {
    const point = asRecord(entry);
    if (point === null) continue;
    const { x, y } = point;
    if (typeof x !== 'number' || !Number.isFinite(x)) continue;
    if (typeof y !== 'number' || !Number.isFinite(y)) continue;
    out[displayId] = { x: Math.round(x), y: Math.round(y) };
  }
  return out;
}

function isPreferenceKey(key: PropertyKey): boolean {
  return Object.prototype.hasOwnProperty.call(DEFAULT_PREFERENCES, key);
}

/* -------------------------------------------------------------------------- */
/* Store                                                                       */
/* -------------------------------------------------------------------------- */

export class PreferencesStore {
  private readonly defaults: Preferences;
  private readonly store: Store<Preferences>;
  private readonly listeners = new Set<PreferencesListener>();

  /** Must be constructed after `app.whenReady()` — `electron-store` needs `userData`. */
  constructor(platformDefaults: { showMiniWindow: boolean }) {
    this.defaults = {
      ...DEFAULT_PREFERENCES,
      showMiniWindow: platformDefaults.showMiniWindow,
      miniWindowPositions: {},
    };
    this.store = new Store<Preferences>({ name: 'preferences', defaults: this.defaults });
  }

  getAll(): Preferences {
    return this.sanitise(this.store.store, this.defaults);
  }

  get<K extends keyof Preferences>(key: K): Preferences[K] {
    return this.getAll()[key];
  }

  /**
   * Writes one preference and returns the resulting full set.
   *
   * An unknown key is ignored rather than stored: `set` is reachable from IPC, and a
   * renderer must not be able to grow the preferences file with arbitrary content.
   */
  set<K extends keyof Preferences>(key: K, value: Preferences[K]): Preferences {
    const current = this.getAll();
    if (!isPreferenceKey(key)) return current;

    const draft: Preferences = { ...current };
    draft[key] = value;
    // Falling back to `current` rather than the defaults: a rejected value must cost
    // the user the write, not the setting they already had.
    const next = this.sanitise(draft, current);

    if (key === 'miniWindowPositions') {
      // Callers only ever know about the display they are on, so a write adds to the
      // map instead of replacing it; other displays keep their remembered position.
      next.miniWindowPositions = { ...current.miniWindowPositions, ...next.miniWindowPositions };
    }

    this.store.store = next;
    this.notify(next);
    return next;
  }

  reset(): Preferences {
    const next = this.sanitise(this.defaults, this.defaults);
    this.store.store = next;
    this.notify(next);
    return next;
  }

  onChange(listener: PreferencesListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private notify(prefs: Preferences): void {
    // Copied so a listener that unsubscribes itself cannot disturb the iteration, and
    // isolated so one bad listener cannot stop the others from being told.
    for (const listener of [...this.listeners]) {
      try {
        listener(prefs);
      } catch (error) {
        console.error('[preferences] change listener failed', error);
      }
    }
  }

  /**
   * Builds a complete, in-range `Preferences` from anything at all. Each key that is
   * missing or malformed takes its value from `fallback`, independently of the rest.
   */
  private sanitise(raw: unknown, fallback: Preferences): Preferences {
    const d = fallback;
    const r = asRecord(raw) ?? {};

    return {
      launchAtLogin: asBoolean(r.launchAtLogin, d.launchAtLogin),
      showMiniWindow: asBoolean(r.showMiniWindow, d.showMiniWindow),

      idleDetectionEnabled: asBoolean(r.idleDetectionEnabled, d.idleDetectionEnabled),
      idleThresholdMinutes: asIntegerInRange(
        r.idleThresholdMinutes,
        IDLE_THRESHOLD_MIN_MINUTES,
        IDLE_THRESHOLD_MAX_MINUTES,
        d.idleThresholdMinutes,
      ),

      autoPauseOnSleep: asBoolean(r.autoPauseOnSleep, d.autoPauseOnSleep),
      autoPauseOnLock: asBoolean(r.autoPauseOnLock, d.autoPauseOnLock),

      // Fractional targets are meaningful (7.5h), so this one is not rounded.
      dailyTargetHours: asNumberInRange(r.dailyTargetHours, 0, DAILY_TARGET_MAX_HOURS, d.dailyTargetHours),

      reminderEnabled: asBoolean(r.reminderEnabled, d.reminderEnabled),
      reminderHour: asIntegerInRange(r.reminderHour, 0, 23, d.reminderHour),
      reminderMinute: asIntegerInRange(r.reminderMinute, 0, 59, d.reminderMinute),

      theme: asTheme(r.theme, d.theme),
      weekStartsOn: asWeekStart(r.weekStartsOn, d.weekStartsOn),

      miniWindowPositions: asPositions(r.miniWindowPositions, d.miniWindowPositions),

      trayFallbackNoticeShown: asBoolean(r.trayFallbackNoticeShown, d.trayFallbackNoticeShown),

      updateCheckEnabled: asBoolean(r.updateCheckEnabled, d.updateCheckEnabled),
    };
  }
}

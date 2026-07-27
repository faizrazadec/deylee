/**
 * Core domain types for Dayly.
 *
 * Every instant in this app is stored and passed around as UTC epoch milliseconds
 * (`EpochMs`). Calendar days are identified by a `DateKey` derived from the *local*
 * timezone at the moment of derivation. Never format or compare timestamps by string.
 */

/** UTC epoch milliseconds. The only wire format for an instant. */
export type EpochMs = number;

/** A local calendar date, `YYYY-MM-DD`. Sorts lexicographically. */
export type DateKey = string;

export type SegmentType = 'work' | 'break';

/**
 * Timer lifecycle.
 *
 *   IDLE ──start──▶ RUNNING ──pause──▶ PAUSED ──resume──▶ RUNNING ...
 *                      │                  │
 *                      └──── endDay ──────┴──▶ ENDED
 *
 * ENDED means "today's session is finalised". Starting again after ENDED reopens the
 * same day with a fresh work segment (the day row is un-finalised).
 */
export type TimerState = 'IDLE' | 'RUNNING' | 'PAUSED' | 'ENDED';

/** A contiguous span of work or break. `endedAt === null` means it is still open. */
export interface Segment {
  id: number;
  dayId: number;
  type: SegmentType;
  startedAt: EpochMs;
  endedAt: EpochMs | null;
  note: string | null;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

/**
 * A day is the atomic unit. It deliberately stores **no** totals — every total is
 * derived by summing segments, so the numbers survive crashes, restarts and edits.
 */
export interface Day {
  id: number;
  date: DateKey;
  createdAt: EpochMs;
  /** Set when the user presses End Day; cleared if they start again. */
  endedAt: EpochMs | null;
  /** Snapshot of the daily target when the day was created, in minutes. */
  targetMinutes: number;
}

/** Derived aggregates for a single day. Never persisted. */
export interface DayTotals {
  workedMs: number;
  breakMs: number;
  firstStartAt: EpochMs | null;
  lastEndAt: EpochMs | null;
  segmentCount: number;
  /** True when any segment on this day is still open. */
  hasOpenSegment: boolean;
}

export interface DayDetail {
  day: Day;
  /** Ordered by `startedAt` ascending. */
  segments: Segment[];
  totals: DayTotals;
}

/**
 * The single source of truth pushed to every renderer.
 *
 * The live display is computed as
 *   worked = closedWorkedMs + (openSegment?.type === 'work' ? now - clampedStart : 0)
 * where `clampedStart = max(openSegment.startedAt, startOfLocalDay(now))`.
 *
 * Renderers must call `liveTotals(snapshot, Date.now())` on a 1s tick rather than
 * incrementing a counter, so the display stays correct across sleep and clock changes.
 */
export interface TimerSnapshot {
  state: TimerState;
  /** The local calendar date this snapshot describes. */
  date: DateKey;
  dayId: number | null;
  /** Sum of segments on `date` that are already closed. */
  closedWorkedMs: number;
  closedBreakMs: number;
  /** The one open segment, if any. At most one may exist at a time, app-wide. */
  openSegment: Segment | null;
  firstStartAt: EpochMs | null;
  lastEndAt: EpochMs | null;
  /** Daily target in minutes, for the progress bar. */
  targetMinutes: number;
  /** When the main process produced this snapshot. */
  asOf: EpochMs;
}

/** Live, tick-time totals derived from a snapshot. */
export interface LiveTotals {
  workedMs: number;
  breakMs: number;
  /** 0..1+, worked / target. Not clamped — it may exceed 1. */
  targetProgress: number;
  targetMs: number;
  /** ms remaining to hit the target; negative once exceeded. */
  remainingToTargetMs: number;
}

/* -------------------------------------------------------------------------- */
/* Preferences                                                                 */
/* -------------------------------------------------------------------------- */

export interface MiniWindowPosition {
  x: number;
  y: number;
}

export interface Preferences {
  launchAtLogin: boolean;
  showMiniWindow: boolean;

  idleDetectionEnabled: boolean;
  /** Minutes of system idle before prompting. */
  idleThresholdMinutes: number;

  autoPauseOnSleep: boolean;
  autoPauseOnLock: boolean;

  dailyTargetHours: number;

  reminderEnabled: boolean;
  /** 0-23, local. */
  reminderHour: number;
  /** 0-59, local. */
  reminderMinute: number;

  theme: 'system' | 'light' | 'dark';
  /** 0 = Sunday, 1 = Monday. */
  weekStartsOn: 0 | 1;

  /** Mini-window position remembered per display, keyed by `display.id`. */
  miniWindowPositions: Record<string, MiniWindowPosition>;

  /** True once the Linux "no tray available" notice has been shown. */
  trayFallbackNoticeShown: boolean;

  /**
   * The one and only thing Dayly sends over the network: a poll of the GitHub
   * Releases feed. No account, no telemetry, no payload — just a version comparison.
   * Turning this off makes the app completely offline again.
   */
  updateCheckEnabled: boolean;
}

/* -------------------------------------------------------------------------- */
/* Updates                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Update lifecycle as the renderer sees it.
 *
 * `manual` is the honest outcome on platforms that cannot self-update — macOS
 * (Squirrel.Mac refuses unsigned builds) and .deb (no updater at all). Rather than
 * pretending, the app points at the Releases page.
 */
export type UpdateStatus =
  | { kind: 'idle' }
  | { kind: 'checking' }
  | { kind: 'up-to-date'; checkedAt: EpochMs }
  | { kind: 'available'; version: string }
  | { kind: 'downloading'; version: string; percent: number }
  | { kind: 'downloaded'; version: string }
  | { kind: 'manual'; version: string; url: string }
  | { kind: 'unsupported'; reason: string }
  | { kind: 'error'; message: string };

export interface UpdateInfo {
  currentVersion: string;
  /** False on macOS and .deb builds, and in dev. */
  canAutoUpdate: boolean;
  releasesUrl: string;
}

/* -------------------------------------------------------------------------- */
/* Platform                                                                    */
/* -------------------------------------------------------------------------- */

export type OsKind = 'darwin' | 'win32' | 'linux';

export interface PlatformInfo {
  os: OsKind;
  /** False on Linux desktops with no StatusNotifierItem host. */
  trayAvailable: boolean;
  /** Only macOS can render live text next to the tray icon. */
  supportsTrayTitle: boolean;
  /** Whether the mini-window defaults to on for this OS. */
  miniWindowDefaultOn: boolean;
  /** Set when the tray was unavailable and the mini-window was forced on. */
  trayFallbackActive: boolean;
}

/* -------------------------------------------------------------------------- */
/* Prompts (crash recovery, idle, sleep/lock)                                  */
/* -------------------------------------------------------------------------- */

export type RecoveryChoice = 'resume' | 'close-at-heartbeat' | 'discard';

/** Presented at launch when a segment was left open by a quit or crash. */
export interface PendingRecovery {
  segment: Segment;
  date: DateKey;
  lastHeartbeatAt: EpochMs | null;
  /** Duration that would be kept by `close-at-heartbeat`. */
  recoverableMs: number;
  /** Unaccounted time between the last heartbeat and now. */
  gapMs: number;
}

export type IdleChoice = 'keep' | 'discard';

export interface IdlePrompt {
  /** Correlates the prompt with its resolution; prompts are not interchangeable. */
  id: string;
  segmentId: number;
  idleStartedAt: EpochMs;
  idleMs: number;
}

export type WakeChoice = 'resume' | 'count-as-break';

export type WakeReason = 'suspend' | 'lock-screen';

export interface WakePrompt {
  id: string;
  reason: WakeReason;
  gapStartedAt: EpochMs;
  gapEndedAt: EpochMs;
  gapMs: number;
}

/** A one-off informational message surfaced in the panel. */
export interface Notice {
  id: string;
  level: 'info' | 'warning';
  title: string;
  body: string;
}

/* -------------------------------------------------------------------------- */
/* History / aggregation                                                       */
/* -------------------------------------------------------------------------- */

export interface DateRange {
  /** Inclusive. */
  from: DateKey;
  /** Inclusive. */
  to: DateKey;
}

export interface RangeSummary {
  range: DateRange;
  days: DayDetail[];
  totalWorkedMs: number;
  totalBreakMs: number;
  /** Days in the range with at least one work segment. */
  activeDayCount: number;
  /** totalWorkedMs / activeDayCount, or 0 when there are no active days. */
  averageWorkedMsPerActiveDay: number;
  /** Days that met or exceeded their target. */
  targetMetCount: number;
}

/* -------------------------------------------------------------------------- */
/* Mutations                                                                   */
/* -------------------------------------------------------------------------- */

export type MutationErrorCode =
  | 'overlap'
  | 'invalid-range'
  | 'not-found'
  | 'open-segment-conflict'
  | 'unknown';

export type MutationResult<T> =
  | { ok: true; value: T }
  | { ok: false; code: MutationErrorCode; message: string };

export interface CreateSegmentInput {
  type: SegmentType;
  startedAt: EpochMs;
  endedAt: EpochMs;
  note?: string | null;
}

export interface UpdateSegmentInput {
  id: number;
  type?: SegmentType;
  startedAt?: EpochMs;
  endedAt?: EpochMs | null;
  note?: string | null;
}

/* -------------------------------------------------------------------------- */
/* Export / backup                                                             */
/* -------------------------------------------------------------------------- */

export type ExportFormat = 'csv' | 'json';

/** `cancelled` is a normal outcome — the user dismissed the save dialog. */
export type FileWriteResult =
  | { ok: true; path: string }
  | { ok: false; cancelled: true }
  | { ok: false; cancelled: false; message: string };

/* -------------------------------------------------------------------------- */
/* Window identity                                                             */
/* -------------------------------------------------------------------------- */

export type WindowKind = 'panel' | 'mini' | 'history' | 'settings';

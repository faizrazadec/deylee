/**
 * The complete IPC contract between main and renderers.
 *
 * Everything crossing the bridge is declared here. `contextIsolation` is on and
 * `nodeIntegration` is off, so the preload exposes exactly `DaylyApi` on
 * `window.dayly` and nothing else. Renderers never import Electron.
 */

import type {
  CreateSegmentInput,
  DateKey,
  DateRange,
  DayDetail,
  ExportFormat,
  FileWriteResult,
  IdleChoice,
  IdlePrompt,
  MutationResult,
  Notice,
  PendingRecovery,
  PlatformInfo,
  Preferences,
  RangeSummary,
  RecoveryChoice,
  TimerSnapshot,
  UpdateInfo,
  UpdateSegmentInput,
  UpdateStatus,
  WakeChoice,
  WakePrompt,
  WindowKind,
} from './types';

/** Returned by every `on*` subscription; call it to detach the listener. */
export type Unsubscribe = () => void;

/* -------------------------------------------------------------------------- */
/* Channel names                                                               */
/* -------------------------------------------------------------------------- */

/** Renderer -> main, request/response (`ipcRenderer.invoke`). */
export const INVOKE = {
  timerGetSnapshot: 'timer:get-snapshot',
  timerStart: 'timer:start',
  timerPause: 'timer:pause',
  timerResume: 'timer:resume',
  timerEndDay: 'timer:end-day',

  historyGetDay: 'history:get-day',
  historyGetRange: 'history:get-range',
  historyCreateSegment: 'history:create-segment',
  historyUpdateSegment: 'history:update-segment',
  historyDeleteSegment: 'history:delete-segment',
  historyExport: 'history:export',

  prefsGetAll: 'prefs:get-all',
  prefsSet: 'prefs:set',
  prefsReset: 'prefs:reset',

  windowsOpen: 'windows:open',
  windowsClose: 'windows:close',
  windowsMiniMoved: 'windows:mini-moved',

  systemGetPlatformInfo: 'system:get-platform-info',
  systemGetDataPath: 'system:get-data-path',
  systemRevealDataFolder: 'system:reveal-data-folder',
  systemBackupDatabase: 'system:backup-database',
  systemQuit: 'system:quit',

  updatesGetInfo: 'updates:get-info',
  updatesGetStatus: 'updates:get-status',
  updatesCheckNow: 'updates:check-now',
  updatesDownload: 'updates:download',
  updatesInstallNow: 'updates:install-now',
  updatesOpenReleases: 'updates:open-releases',

  promptsGetRecovery: 'prompts:get-recovery',
  promptsResolveRecovery: 'prompts:resolve-recovery',
  promptsResolveIdle: 'prompts:resolve-idle',
  promptsResolveWake: 'prompts:resolve-wake',
  promptsDismissNotice: 'prompts:dismiss-notice',
} as const;

/** Main -> renderer, broadcast (`webContents.send`). */
export const EVENT = {
  snapshot: 'event:snapshot',
  prefsChanged: 'event:prefs-changed',
  idlePrompt: 'event:idle-prompt',
  wakePrompt: 'event:wake-prompt',
  recoveryPrompt: 'event:recovery-prompt',
  notice: 'event:notice',
  historyInvalidated: 'event:history-invalidated',
  updateStatus: 'event:update-status',
} as const;

export type InvokeChannel = (typeof INVOKE)[keyof typeof INVOKE];
export type EventChannel = (typeof EVENT)[keyof typeof EVENT];

/** Every channel the preload is allowed to forward. Used as an allow-list. */
export const ALL_INVOKE_CHANNELS: readonly InvokeChannel[] = Object.values(INVOKE);
export const ALL_EVENT_CHANNELS: readonly EventChannel[] = Object.values(EVENT);

/* -------------------------------------------------------------------------- */
/* Payloads that are not already domain types                                  */
/* -------------------------------------------------------------------------- */

export interface ExportRequest {
  format: ExportFormat;
  range: DateRange;
}

export interface CreateSegmentRequest {
  date: DateKey;
  input: CreateSegmentInput;
}

export interface PrefsSetRequest<K extends keyof Preferences = keyof Preferences> {
  key: K;
  value: Preferences[K];
}

export interface MiniMovedRequest {
  x: number;
  y: number;
}

export interface ResolveIdleRequest {
  promptId: string;
  choice: IdleChoice;
}

export interface ResolveWakeRequest {
  promptId: string;
  choice: WakeChoice;
}

/** Emitted whenever stored day/segment data changed, so History can refetch. */
export interface HistoryInvalidated {
  /** Dates affected; empty means "everything". */
  dates: DateKey[];
}

/* -------------------------------------------------------------------------- */
/* The API surface exposed on `window.dayly`                                   */
/* -------------------------------------------------------------------------- */

export interface TimerApi {
  getSnapshot(): Promise<TimerSnapshot>;
  start(): Promise<TimerSnapshot>;
  pause(): Promise<TimerSnapshot>;
  resume(): Promise<TimerSnapshot>;
  endDay(): Promise<TimerSnapshot>;
  /** Fires on every state change and on the 30s heartbeat. */
  onSnapshot(listener: (snapshot: TimerSnapshot) => void): Unsubscribe;
}

export interface HistoryApi {
  getDay(date: DateKey): Promise<DayDetail | null>;
  getRange(range: DateRange): Promise<RangeSummary>;
  createSegment(request: CreateSegmentRequest): Promise<MutationResult<DayDetail>>;
  updateSegment(input: UpdateSegmentInput): Promise<MutationResult<DayDetail>>;
  deleteSegment(id: number): Promise<MutationResult<DayDetail | null>>;
  exportData(request: ExportRequest): Promise<FileWriteResult>;
  onInvalidated(listener: (payload: HistoryInvalidated) => void): Unsubscribe;
}

export interface PrefsApi {
  getAll(): Promise<Preferences>;
  set<K extends keyof Preferences>(key: K, value: Preferences[K]): Promise<Preferences>;
  reset(): Promise<Preferences>;
  onChanged(listener: (prefs: Preferences) => void): Unsubscribe;
}

export interface WindowsApi {
  open(kind: WindowKind): Promise<void>;
  close(kind: WindowKind): Promise<void>;
  /** Reports the mini-window's new position so it can be remembered per display. */
  reportMiniMoved(position: MiniMovedRequest): Promise<void>;
}

export interface SystemApi {
  getPlatformInfo(): Promise<PlatformInfo>;
  getDataPath(): Promise<string>;
  revealDataFolder(): Promise<void>;
  backupDatabase(): Promise<FileWriteResult>;
  quit(): Promise<void>;
}

export interface PromptsApi {
  getRecovery(): Promise<PendingRecovery | null>;
  resolveRecovery(choice: RecoveryChoice): Promise<TimerSnapshot>;
  resolveIdle(request: ResolveIdleRequest): Promise<TimerSnapshot>;
  resolveWake(request: ResolveWakeRequest): Promise<TimerSnapshot>;
  dismissNotice(id: string): Promise<void>;

  onRecoveryPrompt(listener: (prompt: PendingRecovery) => void): Unsubscribe;
  onIdlePrompt(listener: (prompt: IdlePrompt) => void): Unsubscribe;
  onWakePrompt(listener: (prompt: WakePrompt) => void): Unsubscribe;
  onNotice(listener: (notice: Notice) => void): Unsubscribe;
}

export interface UpdatesApi {
  getInfo(): Promise<UpdateInfo>;
  getStatus(): Promise<UpdateStatus>;
  /** Explicit user-initiated check; runs even when the pref is off. */
  checkNow(): Promise<UpdateStatus>;
  /** Downloads are never automatic — this is the consent step. */
  download(): Promise<UpdateStatus>;
  /** Quits and installs immediately. Only valid from the `downloaded` state. */
  installNow(): Promise<void>;
  /** Opens the Releases page in the default browser (the macOS / .deb path). */
  openReleases(): Promise<void>;
  onStatus(listener: (status: UpdateStatus) => void): Unsubscribe;
}

export interface DaylyApi {
  /** Which window this renderer is, resolved at preload time from the URL. */
  readonly windowKind: WindowKind;
  readonly timer: TimerApi;
  readonly history: HistoryApi;
  readonly prefs: PrefsApi;
  readonly windows: WindowsApi;
  readonly system: SystemApi;
  readonly prompts: PromptsApi;
  readonly updates: UpdatesApi;
}

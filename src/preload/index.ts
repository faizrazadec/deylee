/**
 * The renderer's only door to the main process.
 *
 * `contextIsolation` is on and `sandbox` is on, so this script is bundled to CommonJS
 * and may only touch `electron` plus code bundled into it — no node built-ins at
 * runtime. Exactly `DaylyApi` is exposed on `window.dayly`; nothing else, ever.
 *
 * Channels are checked against the allow-lists in `@shared/ipc` before they are used.
 * Every call site already passes an `INVOKE`/`EVENT` constant, so the check can only
 * fire if this file drifts from the contract — which is precisely when it should.
 */

import { contextBridge, ipcRenderer } from 'electron';
import type { IpcRendererEvent } from 'electron';

import { ALL_EVENT_CHANNELS, ALL_INVOKE_CHANNELS, EVENT, INVOKE } from '@shared/ipc';
import type {
  CreateSegmentRequest,
  DaylyApi,
  EventChannel,
  ExportRequest,
  HistoryInvalidated,
  InvokeChannel,
  MiniMovedRequest,
  PrefsSetRequest,
  ResolveIdleRequest,
  ResolveWakeRequest,
  Unsubscribe,
} from '@shared/ipc';
import type {
  DateKey,
  DateRange,
  DayDetail,
  FileWriteResult,
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
  WakePrompt,
  WindowKind,
} from '@shared/types';

/**
 * The preload is compiled alongside the main process, which has no DOM lib, yet it runs
 * in the renderer. Declaring the single browser global it needs is cheaper than pulling
 * `lib.dom` into every main-process file.
 */
declare const location: { readonly pathname: string };

const ALLOWED_INVOKE: ReadonlySet<string> = new Set<string>(ALL_INVOKE_CHANNELS);
const ALLOWED_EVENTS: ReadonlySet<string> = new Set<string>(ALL_EVENT_CHANNELS);

const WINDOW_KINDS: readonly WindowKind[] = ['panel', 'mini', 'history', 'settings'];

/** `/panel.html` → `panel`. Anything unrecognised is the panel. */
function resolveWindowKind(): WindowKind {
  const file = location.pathname.split('/').pop() ?? '';
  const name = file.endsWith('.html') ? file.slice(0, -'.html'.length) : file;
  for (const kind of WINDOW_KINDS) {
    if (kind === name) return kind;
  }
  return 'panel';
}

/**
 * `ipcRenderer.invoke` is typed as `Promise<any>`; funnelling every call through here
 * means that `any` is absorbed into `unknown` in exactly one place, and the declared
 * `DaylyApi` return types are the only thing renderers ever see.
 */
async function invoke<T>(channel: InvokeChannel, ...args: readonly unknown[]): Promise<T> {
  if (!ALLOWED_INVOKE.has(channel)) {
    throw new Error(`Blocked IPC channel: ${channel}`);
  }
  const result: unknown = await ipcRenderer.invoke(channel, ...args);
  return result as T;
}

/** Listeners receive only the payload — the `IpcRendererEvent` never leaves this file. */
function subscribe<T>(channel: EventChannel, listener: (payload: T) => void): Unsubscribe {
  if (!ALLOWED_EVENTS.has(channel)) {
    return () => undefined;
  }
  const forward = (_event: IpcRendererEvent, payload: unknown): void => {
    listener(payload as T);
  };
  ipcRenderer.on(channel, forward);
  return () => {
    ipcRenderer.removeListener(channel, forward);
  };
}

const api: DaylyApi = {
  windowKind: resolveWindowKind(),

  timer: {
    getSnapshot: () => invoke<TimerSnapshot>(INVOKE.timerGetSnapshot),
    start: () => invoke<TimerSnapshot>(INVOKE.timerStart),
    pause: () => invoke<TimerSnapshot>(INVOKE.timerPause),
    resume: () => invoke<TimerSnapshot>(INVOKE.timerResume),
    endDay: () => invoke<TimerSnapshot>(INVOKE.timerEndDay),
    onSnapshot: (listener: (snapshot: TimerSnapshot) => void) =>
      subscribe<TimerSnapshot>(EVENT.snapshot, listener),
  },

  history: {
    getDay: (date: DateKey) => invoke<DayDetail | null>(INVOKE.historyGetDay, date),
    getRange: (range: DateRange) => invoke<RangeSummary>(INVOKE.historyGetRange, range),
    createSegment: (request: CreateSegmentRequest) =>
      invoke<MutationResult<DayDetail>>(INVOKE.historyCreateSegment, request),
    updateSegment: (input: UpdateSegmentInput) =>
      invoke<MutationResult<DayDetail>>(INVOKE.historyUpdateSegment, input),
    deleteSegment: (id: number) =>
      invoke<MutationResult<DayDetail | null>>(INVOKE.historyDeleteSegment, id),
    exportData: (request: ExportRequest) => invoke<FileWriteResult>(INVOKE.historyExport, request),
    onInvalidated: (listener: (payload: HistoryInvalidated) => void) =>
      subscribe<HistoryInvalidated>(EVENT.historyInvalidated, listener),
  },

  prefs: {
    getAll: () => invoke<Preferences>(INVOKE.prefsGetAll),
    set: <K extends keyof Preferences>(key: K, value: Preferences[K]) =>
      invoke<Preferences>(INVOKE.prefsSet, { key, value } satisfies PrefsSetRequest<K>),
    reset: () => invoke<Preferences>(INVOKE.prefsReset),
    onChanged: (listener: (prefs: Preferences) => void) =>
      subscribe<Preferences>(EVENT.prefsChanged, listener),
  },

  windows: {
    open: (kind: WindowKind) => invoke<void>(INVOKE.windowsOpen, kind),
    close: (kind: WindowKind) => invoke<void>(INVOKE.windowsClose, kind),
    reportMiniMoved: (position: MiniMovedRequest) =>
      invoke<void>(INVOKE.windowsMiniMoved, position),
  },

  system: {
    getPlatformInfo: () => invoke<PlatformInfo>(INVOKE.systemGetPlatformInfo),
    getDataPath: () => invoke<string>(INVOKE.systemGetDataPath),
    revealDataFolder: () => invoke<void>(INVOKE.systemRevealDataFolder),
    backupDatabase: () => invoke<FileWriteResult>(INVOKE.systemBackupDatabase),
    quit: () => invoke<void>(INVOKE.systemQuit),
  },

  prompts: {
    getRecovery: () => invoke<PendingRecovery | null>(INVOKE.promptsGetRecovery),
    resolveRecovery: (choice: RecoveryChoice) =>
      invoke<TimerSnapshot>(INVOKE.promptsResolveRecovery, choice),
    resolveIdle: (request: ResolveIdleRequest) =>
      invoke<TimerSnapshot>(INVOKE.promptsResolveIdle, request),
    resolveWake: (request: ResolveWakeRequest) =>
      invoke<TimerSnapshot>(INVOKE.promptsResolveWake, request),
    dismissNotice: (id: string) => invoke<void>(INVOKE.promptsDismissNotice, id),

    onRecoveryPrompt: (listener: (prompt: PendingRecovery) => void) =>
      subscribe<PendingRecovery>(EVENT.recoveryPrompt, listener),
    onIdlePrompt: (listener: (prompt: IdlePrompt) => void) =>
      subscribe<IdlePrompt>(EVENT.idlePrompt, listener),
    onWakePrompt: (listener: (prompt: WakePrompt) => void) =>
      subscribe<WakePrompt>(EVENT.wakePrompt, listener),
    onNotice: (listener: (notice: Notice) => void) => subscribe<Notice>(EVENT.notice, listener),
  },

  updates: {
    getInfo: () => invoke<UpdateInfo>(INVOKE.updatesGetInfo),
    getStatus: () => invoke<UpdateStatus>(INVOKE.updatesGetStatus),
    checkNow: () => invoke<UpdateStatus>(INVOKE.updatesCheckNow),
    download: () => invoke<UpdateStatus>(INVOKE.updatesDownload),
    // Resolves only if the install does *not* happen: a successful call quits the app.
    installNow: () => invoke<void>(INVOKE.updatesInstallNow),
    openReleases: () => invoke<void>(INVOKE.updatesOpenReleases),
    onStatus: (listener: (status: UpdateStatus) => void) =>
      subscribe<UpdateStatus>(EVENT.updateStatus, listener),
  },
};

contextBridge.exposeInMainWorld('dayly', api);

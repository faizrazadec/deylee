/**
 * Main process entry.
 *
 * Startup is deliberately ordered (see ARCHITECTURE §9): the single-instance lock is
 * taken before anything touches the database, the session is hardened before a window
 * can exist, and crash recovery is decided before the timer is allowed to run.
 *
 * Dayly is a tray application. The only network call it ever makes is the update check
 * in `UpdateService`, which is a preference away from off. Closing every window does not
 * quit; only the tray menu or `INVOKE.systemQuit` does.
 */

import { Notification, app, dialog, session } from 'electron';
import { randomUUID } from 'node:crypto';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import { EVENT } from '@shared/ipc';
import type { HistoryInvalidated } from '@shared/ipc';
import { formatCompact } from '@shared/time';
import type {
  EpochMs,
  IdleChoice,
  IdlePrompt,
  Notice,
  PendingRecovery,
  PlatformInfo,
  Preferences,
  RecoveryChoice,
  TimerSnapshot,
  UpdateStatus,
  WakeChoice,
  WakePrompt,
  WakeReason,
} from '@shared/types';
import {
  buildPendingRecovery,
  isRecoveryWorthPrompting,
  planIdle,
  planRecovery,
  planWake,
} from '@domain/recovery';
import { openDatabase } from '@main/db/connection';
import { runMigrations, SchemaTooNewError } from '@main/db/migrations';
import { APP_STATE_HEARTBEAT, Repository } from '@main/db/repository';
import { registerIpcHandlers } from '@main/ipc/handlers';
import { createPlatform } from '@main/platform/Platform';
import type { Platform } from '@main/platform/Platform';
import { HeartbeatService } from '@main/services/HeartbeatService';
import { IdleMonitor } from '@main/services/IdleMonitor';
import { PowerMonitorService } from '@main/services/PowerMonitorService';
import { ReminderService } from '@main/services/ReminderService';
import { TimerService } from '@main/services/TimerService';
import { UpdateService } from '@main/services/UpdateService';
import { PreferencesStore } from '@main/store/preferences';
import { TrayController } from '@main/tray/TrayController';
import { WindowManager } from '@main/windows/WindowManager';

/** Everything constructed at startup, so shutdown has one place to look. */
interface Runtime {
  platform: Platform;
  prefs: PreferencesStore;
  repo: Repository;
  timer: TimerService;
  heartbeat: HeartbeatService;
  idle: IdleMonitor;
  power: PowerMonitorService;
  reminder: ReminderService;
  updates: UpdateService;
  windows: WindowManager;
  tray: TrayController;
  readonly subscriptions: Array<() => void>;
  rollover: NodeJS.Timeout | null;
}

let runtime: Runtime | null = null;

/**
 * Raised the moment a quit is requested. Every periodic task checks it so nothing
 * re-opens a window or touches the database while the process is tearing down.
 */
let quitting = false;
let tornDown = false;

let pendingRecovery: PendingRecovery | null = null;
const idlePrompts = new Map<string, IdlePrompt>();
const wakePrompts = new Map<string, WakePrompt>();

/** True only when *we* closed a work segment because the machine went away. */
let autoPausedByPower = false;
let heartbeatRunning = false;
let launchAtLoginApplied: boolean | null = null;
let trayAvailable = true;
let trayFallbackActive = false;
/** Answered once at startup; assume yes until then. */
let idleAvailable = true;

/* -------------------------------------------------------------------------- */
/* 6. Session hardening                                                        */
/* -------------------------------------------------------------------------- */

const PRODUCTION_CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "connect-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
].join('; ');

/**
 * The dev server needs more rope than production: `@vitejs/plugin-react` injects an
 * inline refresh preamble, and HMR talks over a websocket. None of this is shipped —
 * `ELECTRON_RENDERER_URL` is only set by `electron-vite dev`.
 */
function developmentCsp(origin: string): string {
  return [
    `default-src 'self' ${origin}`,
    `script-src 'self' 'unsafe-inline' ${origin}`,
    `style-src 'self' 'unsafe-inline' ${origin}`,
    `img-src 'self' data: ${origin}`,
    `connect-src 'self' ${origin} ws: wss:`,
    "object-src 'none'",
    "base-uri 'none'",
  ].join('; ');
}

function devServerOrigin(): string | null {
  const origin = process.env.ELECTRON_RENDERER_URL;
  return origin === undefined || origin.length === 0 ? null : origin;
}

function hardenSession(): void {
  const origin = devServerOrigin();
  const policy = origin === null ? PRODUCTION_CSP : developmentCsp(origin);
  const { defaultSession } = session;

  defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: { ...details.responseHeaders, 'Content-Security-Policy': [policy] },
    });
  });

  // Nothing in a local time tracker needs the camera, the microphone, geolocation or
  // any other gated capability, so every request and every check is refused.
  defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => {
    callback(false);
  });
  defaultSession.setPermissionCheckHandler(() => false);
}

/** Nothing may navigate away from, or open a window outside, the app's own origin. */
function guardNavigation(): void {
  const origin = devServerOrigin();
  const rendererRoot = pathToFileURL(join(__dirname, '../renderer/')).href;

  const isOwnUrl = (target: string): boolean => {
    if (origin !== null && target.startsWith(origin)) return true;
    return target.startsWith(rendererRoot);
  };

  app.on('web-contents-created', (_event, contents) => {
    contents.setWindowOpenHandler(() => ({ action: 'deny' }));
    contents.on('will-navigate', (details) => {
      if (!isOwnUrl(details.url)) details.preventDefault();
    });
  });
}

/* -------------------------------------------------------------------------- */
/* 5. Schema guard — a database from the future                                */
/* -------------------------------------------------------------------------- */

/**
 * Says what happened and leaves, without having opened a single transaction.
 *
 * Downgrading and "helpfully" migrating anyway would silently drop whatever the newer
 * build had added, so the untouched file *is* the safe outcome. The message names both
 * versions because "update Dayly" is only actionable if the user can see which side is
 * behind.
 */
function refuseNewerSchema(error: SchemaTooNewError): void {
  console.error('[dayly] refusing a database from a newer build:', error);
  dialog.showErrorBox(
    'This data was written by a newer Dayly',
    [
      `Your database is at schema version ${error.storedVersion}, but this build — ` +
        `Dayly ${app.getVersion()} — only understands version ${error.supportedVersion}.`,
      '',
      'Nothing has been changed and nothing has been lost. Update Dayly to the latest',
      'release and your data will open again exactly as you left it.',
    ].join('\n'),
  );
  app.quit();
}

/* -------------------------------------------------------------------------- */
/* 7. Crash recovery                                                           */
/* -------------------------------------------------------------------------- */

function readHeartbeat(repo: Repository): EpochMs | null {
  const stored = repo.getAppState(APP_STATE_HEARTBEAT);
  if (stored === null || stored.trim().length === 0) return null;
  const parsed = Number(stored);
  return Number.isFinite(parsed) ? parsed : null;
}

function detectRecovery(repo: Repository): PendingRecovery | null {
  const open = repo.findOpenSegment();
  if (open === null) return null;
  return buildPendingRecovery(open, readHeartbeat(repo), Date.now());
}

function applyStartupRecovery(rt: Runtime, pending: PendingRecovery | null): void {
  if (pending === null) return;

  if (!isRecoveryWorthPrompting(pending)) {
    // A segment opened seconds before the crash holds no time worth a dialog.
    rt.timer.applyRecovery(planRecovery(pending, 'discard'));
    return;
  }

  pendingRecovery = pending;
  deliverToPanel(rt, () => {
    rt.windows.broadcast<PendingRecovery>(EVENT.recoveryPrompt, pending);
  });
}

function applyRecoveryChoice(rt: Runtime, choice: RecoveryChoice): TimerSnapshot {
  const pending = pendingRecovery;
  if (pending === null) return rt.timer.getSnapshot();
  pendingRecovery = null;
  return rt.timer.applyRecovery(planRecovery(pending, choice));
}

/* -------------------------------------------------------------------------- */
/* Idle, sleep and lock prompts                                                */
/* -------------------------------------------------------------------------- */

/**
 * Opens the panel and sends once it can actually receive. A window that is still
 * loading would drop the event, and only the recovery prompt has a catch-up read.
 */
function deliverToPanel(rt: Runtime, send: () => void): void {
  const panel = rt.windows.open('panel');
  if (panel.webContents.isLoading()) {
    panel.webContents.once('did-finish-load', send);
    return;
  }
  send();
}

function notify(title: string, body: string): void {
  if (!Notification.isSupported()) return;
  const notification = new Notification({ title, body });
  // A dismissed notification must never be the only way to answer, so clicking it
  // brings up the panel, which shows the same prompt.
  notification.on('click', () => {
    runtime?.windows.open('panel');
  });
  notification.show();
}

function announceIdlePrompt(idleStartedAt: EpochMs, idleMs: EpochMs): void {
  const rt = runtime;
  if (rt === null || quitting) return;

  const open = rt.timer.getSnapshot().openSegment;
  if (open === null || open.type !== 'work') return;

  const prompt: IdlePrompt = { id: randomUUID(), segmentId: open.id, idleStartedAt, idleMs };
  idlePrompts.set(prompt.id, prompt);
  deliverToPanel(rt, () => {
    rt.windows.broadcast<IdlePrompt>(EVENT.idlePrompt, prompt);
  });
  notify('You were away', `Dayly kept counting for ${formatCompact(idleMs)}. Keep it or drop it?`);
}

function applyIdleChoice(rt: Runtime, promptId: string, choice: IdleChoice): TimerSnapshot {
  const prompt = idlePrompts.get(promptId);
  // Prompts are not interchangeable: an unknown id is a stale UI, not a decision.
  if (prompt === undefined) return rt.timer.getSnapshot();
  idlePrompts.delete(promptId);

  const segment = rt.repo.getSegment(prompt.segmentId);
  if (segment === null) return rt.timer.getSnapshot();
  return rt.timer.applyIdle(planIdle(segment, prompt.idleStartedAt, choice));
}

function handleAway(at: EpochMs): void {
  const rt = runtime;
  if (rt === null) return;

  const open = rt.timer.getSnapshot().openSegment;
  if (open === null || open.type !== 'work') {
    autoPausedByPower = false;
    return;
  }
  rt.timer.suspendAt(at);
  // `suspendAt` refuses to store an empty segment, so whether the work segment really
  // closed is the only honest signal that there is a gap to ask the user about.
  autoPausedByPower = rt.timer.getSnapshot().openSegment === null;
}

function handleBack(awayAt: EpochMs, backAt: EpochMs, reason: WakeReason): void {
  const rt = runtime;
  // Without a matching auto-pause there is no gap to attribute.
  if (rt === null || !autoPausedByPower) return;
  autoPausedByPower = false;

  const prompt: WakePrompt = {
    id: randomUUID(),
    reason,
    gapStartedAt: awayAt,
    gapEndedAt: backAt,
    gapMs: Math.max(0, backAt - awayAt),
  };
  wakePrompts.set(prompt.id, prompt);
  deliverToPanel(rt, () => {
    rt.windows.broadcast<WakePrompt>(EVENT.wakePrompt, prompt);
  });

  const cause = reason === 'lock-screen' ? 'Your screen was locked' : 'This machine was asleep';
  notify('Welcome back', `${cause} for ${formatCompact(prompt.gapMs)}. Count it as a break?`);
}

function applyWakeChoice(rt: Runtime, promptId: string, choice: WakeChoice): TimerSnapshot {
  const prompt = wakePrompts.get(promptId);
  if (prompt === undefined) return rt.timer.getSnapshot();
  wakePrompts.delete(promptId);
  return rt.timer.applyWake(planWake(prompt.gapStartedAt, prompt.gapEndedAt, choice));
}

function announceReminder(): void {
  const rt = runtime;
  if (rt === null) return;
  const notice: Notice = {
    id: randomUUID(),
    level: 'info',
    title: 'Still tracking',
    body: 'Your timer is still running. End the day when you are done.',
  };
  rt.windows.broadcast<Notice>(EVENT.notice, notice);
  notify(notice.title, notice.body);
}

/* -------------------------------------------------------------------------- */
/* Reactions to state and preference changes                                   */
/* -------------------------------------------------------------------------- */

function handleSnapshot(rt: Runtime, snapshot: TimerSnapshot): void {
  if (quitting) return;
  rt.windows.broadcast<TimerSnapshot>(EVENT.snapshot, snapshot);
  rt.idle.setRunning(snapshot.state === 'RUNNING');
  // The heartbeat exists to date a crash, so it only has to run while something is open.
  syncHeartbeat(rt, snapshot.openSegment !== null);
}

function syncHeartbeat(rt: Runtime, shouldRun: boolean): void {
  if (shouldRun === heartbeatRunning) return;
  heartbeatRunning = shouldRun;
  if (shouldRun) rt.heartbeat.start();
  else rt.heartbeat.stop();
}

function handlePrefsChange(rt: Runtime, prefs: Preferences): void {
  rt.windows.broadcast<Preferences>(EVENT.prefsChanged, prefs);
  rt.windows.syncMiniWindow(prefs.showMiniWindow);
  // The IPC write path applies the login item *before* it persists anything, so that a
  // refused registration can be reported instead of confirmed. This stays as the safety
  // net for a change that arrives another way — `prefs.reset()` is reachable over IPC.
  void applyLaunchAtLogin(rt.platform, prefs.launchAtLogin);
  syncTodayTarget(rt);
}

/**
 * Writing a login item touches the OS, so it only happens when the value moves — and
 * the value is recorded only once the OS has accepted it. Remembering a write that
 * failed as applied would mean never retrying it.
 */
async function applyLaunchAtLogin(platform: Platform, enabled: boolean): Promise<void> {
  if (launchAtLoginApplied === enabled) return;
  try {
    await platform.setLoginItemEnabled(enabled);
    launchAtLoginApplied = enabled;
  } catch (error) {
    console.error('[dayly] could not update the login item:', error);
  }
}

/**
 * Reconciles the stored preference against the OS at startup.
 *
 * The login item is one of the few settings the *system* also lets the user change —
 * macOS System Settings, the autostart file, the Run key — which makes the OS, not the
 * store, the truth. Without this the toggle would go on claiming "on" after the user
 * switched Dayly off in System Settings, and the stale preference would silently
 * re-register it on the next launch, overriding the choice they made there.
 */
async function reconcileLaunchAtLogin(rt: Runtime): Promise<void> {
  const stored = rt.prefs.get('launchAtLogin');
  let actual: boolean;
  try {
    actual = await rt.platform.isLoginItemEnabled();
  } catch (error) {
    // With no answer from the OS there is nothing to reconcile against, and guessing in
    // either direction is worse than leaving the preference exactly as the user left it.
    console.error('[dayly] could not read the login item:', error);
    return;
  }

  // Recorded before the write below, so the change listener it triggers sees the value
  // as already applied rather than writing it to the OS a second time.
  launchAtLoginApplied = actual;
  if (actual !== stored) {
    rt.prefs.set('launchAtLogin', actual);
    return;
  }
  if (!actual) return;

  // Both sides agree it is on, but Linux names the executable by path in the autostart
  // entry, and an AppImage the user has moved since leaves an entry pointing at nothing.
  // An entry that is supposed to exist is therefore rewritten rather than trusted; macOS
  // and Windows see the state already matches and do nothing.
  try {
    await rt.platform.setLoginItemEnabled(true);
  } catch (error) {
    console.error('[dayly] could not refresh the login item:', error);
  }
}

/**
 * Re-stamps the day in progress when the daily target changes.
 *
 * Past days keep the target they were actually tracked against — changing the target
 * must never rewrite history — but the day on screen has to follow the number the user
 * just set, or the panel's progress bar and today's cell in History go on answering to
 * the old one until midnight.
 */
function syncTodayTarget(rt: Runtime): void {
  try {
    const changed = rt.timer.syncTodayTarget();
    if (changed.length === 0) return;
    rt.windows.broadcast<HistoryInvalidated>(EVENT.historyInvalidated, { dates: [...changed] });
    // Carries the new target to the panel and the tray in the same breath.
    rt.timer.emit();
  } catch (error) {
    console.error('[dayly] could not apply the new daily target:', error);
  }
}

/* -------------------------------------------------------------------------- */
/* 9. Tray, with the Linux fallback                                            */
/* -------------------------------------------------------------------------- */

async function initialiseTray(rt: Runtime): Promise<void> {
  trayAvailable = await rt.tray.init().catch((error: unknown) => {
    console.error('[dayly] tray initialisation failed:', error);
    return false;
  });
  if (trayAvailable) return;

  // With no tray host the mini-window is the only way to reach the app at all.
  trayFallbackActive = true;
  // Before any window is opened, so the panel is built as an ordinary window rather
  // than a popover with nothing to hang from.
  rt.windows.setTrayFallbackActive(true);
  rt.prefs.set('showMiniWindow', true);
  if (rt.prefs.get('trayFallbackNoticeShown')) return;

  rt.prefs.set('trayFallbackNoticeShown', true);
  deliverToPanel(rt, () => {
    rt.windows.broadcast<Notice>(EVENT.notice, {
      id: randomUUID(),
      level: 'warning',
      title: 'No system tray found',
      body:
        'This desktop does not provide a tray, so the floating mini-window has been ' +
        'turned on instead. Drag it anywhere, or switch it off again in Settings.',
    });
  });
}

/* -------------------------------------------------------------------------- */
/* 10. Midnight rollover                                                       */
/* -------------------------------------------------------------------------- */

/**
 * A segment left running past midnight must split even if nobody touches the app, so
 * the clock is checked every second rather than on a timer aimed at midnight — which a
 * sleeping machine or a clock change would sail straight past.
 */
function startMidnightRollover(rt: Runtime): NodeJS.Timeout {
  const seed = rt.timer.getSnapshot();
  let lastDate = seed.date;
  let lastOpenId: number | null = seed.openSegment === null ? null : seed.openSegment.id;

  return setInterval(() => {
    if (quitting) return;
    try {
      const snapshot = rt.timer.rollOverMidnight();
      const openId = snapshot.openSegment === null ? null : snapshot.openSegment.id;
      if (snapshot.date === lastDate && openId === lastOpenId) return;
      lastDate = snapshot.date;
      lastOpenId = openId;
      rt.windows.broadcast<TimerSnapshot>(EVENT.snapshot, snapshot);
    } catch (error) {
      console.error('[dayly] midnight rollover failed:', error);
    }
  }, 1_000);
}

/* -------------------------------------------------------------------------- */
/* Startup                                                                     */
/* -------------------------------------------------------------------------- */

function describePlatform(rt: Runtime): PlatformInfo {
  return {
    os: rt.platform.os,
    trayAvailable,
    supportsTrayTitle: rt.platform.supportsTrayTitle,
    miniWindowDefaultOn: rt.platform.miniWindowDefaultOn,
    trayFallbackActive,
    supportsLockDetection: rt.platform.supportsLockDetection,
    supportsIdleDetection: idleAvailable,
  };
}

async function bootstrap(): Promise<void> {
  const platform = createPlatform();
  platform.configureApp();

  const prefs = new PreferencesStore({ showMiniWindow: platform.miniWindowDefaultOn });

  const dbPath = join(app.getPath('userData'), 'dayly.sqlite');
  const db = openDatabase(dbPath);
  try {
    runMigrations(db);
  } catch (error) {
    // Any other migration failure is a genuine startup error and belongs to `fail()`.
    if (!(error instanceof SchemaTooNewError)) throw error;
    // Release the handle without writing through it, then stop.
    safely(() => {
      db.close();
    });
    refuseNewerSchema(error);
    return;
  }
  const repo = new Repository(db);

  hardenSession();
  guardNavigation();

  // Recovery is *detected* before the timer exists so that no transition can close the
  // open segment first; the decision is applied further down.
  const detected = detectRecovery(repo);

  const timer = new TimerService({ repo, prefs });
  const heartbeat = new HeartbeatService(repo);
  const windows = new WindowManager({ platform, prefs });
  // Built once the windows exist, because every status change is pushed to all of them.
  // Nothing has gone near the network yet — `start()` is what schedules the first check.
  const updates = new UpdateService({
    platform,
    prefs,
    onStatus: (status) => {
      if (quitting) return;
      windows.broadcast<UpdateStatus>(EVENT.updateStatus, status);
    },
  });
  // Asked once: the answer cannot change without a new session, and the poll must not
  // pay for it every fifteen seconds.
  idleAvailable = await platform.probeIdleAvailable().catch(() => true);
  if (!idleAvailable) {
    console.warn('[dayly] this session cannot report idle time; idle detection is off');
  }

  const idle = new IdleMonitor({
    prefs,
    // Through the platform, because how idle time is read is a per-OS fact and on Linux
    // the obvious source answers 0 forever under confinement.
    readIdleMs: () => platform.readIdleMs(),
    onIdleDetected: announceIdlePrompt,
  });
  const power = new PowerMonitorService({ prefs, onAway: handleAway, onBack: handleBack });
  const reminder = new ReminderService({
    prefs,
    isRunning: () => timer.getSnapshot().state === 'RUNNING',
    onRemind: announceReminder,
  });
  const tray = new TrayController({
    platform,
    timer,
    prefs,
    onTogglePanel: (bounds) => {
      windows.togglePanelNearTray(bounds);
    },
    onOpen: (kind) => {
      windows.open(kind);
    },
    onQuit: requestQuit,
  });

  // Holds the macOS menu-bar highlight for as long as the panel is up. Electron's Tray
  // cannot do this, which is why the macOS platform owns its own NSStatusItem.
  windows.onPanelVisibility((visible) => {
    tray.setPanelOpen(visible);
  });

  const rt: Runtime = {
    platform,
    prefs,
    repo,
    timer,
    heartbeat,
    idle,
    power,
    reminder,
    updates,
    windows,
    tray,
    subscriptions: [],
    rollover: null,
  };
  runtime = rt;

  rt.subscriptions.push(
    timer.onSnapshot((snapshot) => {
      handleSnapshot(rt, snapshot);
    }),
    prefs.onChange((next) => {
      handlePrefsChange(rt, next);
    }),
  );

  registerIpcHandlers({
    repo,
    timer,
    prefs,
    windows,
    platform,
    updates,
    dbPath,
    getPendingRecovery: () => pendingRecovery,
    resolveRecovery: (choice) => applyRecoveryChoice(rt, choice),
    resolveIdle: (promptId, choice) => applyIdleChoice(rt, promptId, choice),
    resolveWake: (promptId, choice) => applyWakeChoice(rt, promptId, choice),
    platformInfo: () => describePlatform(rt),
    // The write path applies the login item before it persists the preference, so a
    // rejection here is what stops a refused registration being reported as saved.
    setLoginItemEnabled: async (enabled) => {
      await platform.setLoginItemEnabled(enabled);
      launchAtLoginApplied = enabled;
    },
  });

  await reconcileLaunchAtLogin(rt);
  windows.syncMiniWindow(prefs.get('showMiniWindow'));

  idle.start();
  power.start();
  reminder.start();
  updates.start();

  await initialiseTray(rt);
  applyStartupRecovery(rt, detected);

  // Seeds the idle monitor, the heartbeat and any window recovery has just changed.
  timer.emit();
  rt.rollover = startMidnightRollover(rt);
}

/* -------------------------------------------------------------------------- */
/* 11 & 12. Lifecycle                                                          */
/* -------------------------------------------------------------------------- */

function focusPanel(): void {
  const rt = runtime;
  if (rt === null || quitting) return;
  const panel = rt.windows.open('panel');
  if (panel.isMinimized()) panel.restore();
  panel.focus();
}

function requestQuit(): void {
  quitting = true;
  app.quit();
}

function safely(step: () => void): void {
  try {
    step();
  } catch (error) {
    console.error('[dayly] shutdown step failed:', error);
  }
}

function teardown(): void {
  if (tornDown) return;
  tornDown = true;

  const rt = runtime;
  runtime = null;
  if (rt === null) return;

  safely(() => {
    if (rt.rollover !== null) clearInterval(rt.rollover);
  });
  for (const unsubscribe of rt.subscriptions) safely(unsubscribe);

  // The last heartbeat is what dates a crash, so it is written before anything stops.
  safely(() => rt.heartbeat.writeNow());
  safely(() => rt.heartbeat.stop());
  safely(() => rt.idle.stop());
  safely(() => rt.power.stop());
  safely(() => rt.reminder.stop());
  // Only stops the polling and detaches our listeners. A staged installer is owned by
  // electron-updater's own quit handler and deliberately survives this.
  safely(() => rt.updates.stop());
  safely(() => rt.tray.destroy());
  safely(() => rt.windows.destroyAll());
  safely(() => rt.repo.close());
}

function fail(error: unknown): void {
  console.error('[dayly] failed to start:', error);
  dialog.showErrorBox(
    'Dayly could not start',
    error instanceof Error ? error.message : String(error),
  );
  app.quit();
}

if (!app.requestSingleInstanceLock()) {
  // A second copy hands its window request to the first instance and steps aside.
  app.quit();
} else {
  app.on('second-instance', focusPanel);

  app.on('window-all-closed', () => {
    // Deliberately empty: Dayly lives in the tray, so closing every window is not the
    // end of the session. Quitting goes through the tray menu or INVOKE.systemQuit.
  });

  app.on('before-quit', () => {
    // Raised here too, because a quit can also come from the OS (log out, ⌘Q).
    quitting = true;

    // Dayly is a tray app that stays open all day, so it never forces a restart to
    // apply an update. A staged one instead rides along with the quit the user chose:
    // consenting to the download armed `autoInstallOnAppQuit`, and electron-updater
    // runs the installer from its own `app.on('quit')` handler — after the teardown
    // below has flushed the heartbeat and closed the database. The read has to happen
    // before `teardown()`, which clears the runtime.
    const installing = runtime !== null && runtime.updates.hasPendingInstall();

    teardown();

    if (installing) {
      console.info('[dayly] a downloaded update will be installed as this quit completes');
    }
  });

  void app.whenReady().then(bootstrap).catch(fail);
}

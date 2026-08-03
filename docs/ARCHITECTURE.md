# Dayly — internal architecture contract

This document is the **single source of truth** for module boundaries. Every module
below is implemented by a different author working in parallel, so the signatures here
are binding: implement them exactly, and call other modules exactly as specified.

Already written and **frozen** — read them, never edit them:

- `src/shared/types.ts` — all domain types
- `src/shared/ipc.ts` — `INVOKE` / `EVENT` channel maps and the `DaylyApi` surface
- `src/shared/time.ts` — local-calendar/DST-safe date maths and formatting
- `src/domain/duration.ts` — `spanDuration`, `spanDurationWithinDay`, `dayTotals`, `liveTotals`
- `src/domain/midnight.ts` — `splitAtMidnight`, `splitOpenSpanAt`, `crossesMidnight`
- `src/domain/overlap.ts` — `intervalsOverlap`, `findOverlapping`, `validateSegment`
- `src/domain/recovery.ts` — `buildPendingRecovery`, `planRecovery`, `planIdle`, `planWake`
- `src/domain/aggregate.ts` — `summariseRange`, `densifyRange`, `weekRange`, `monthRange`

## Hard TypeScript rules (the build enforces all of these)

- `strict: true`, and **no `any`** anywhere — not even `as any`. Use `unknown` + narrowing.
- `verbatimModuleSyntax: true` → type-only imports **must** use `import type { X } from '...'`.
- `noUnusedLocals` / `noUnusedParameters` → no unused imports, variables or parameters.
- `isolatedModules: true` → re-export types as `export type { X }`.
- `noImplicitReturns`, `noFallthroughCasesInSwitch` are on.
- Path aliases: `@shared/*`, `@domain/*`, `@main/*` (node) and `@shared/*`, `@domain/*`,
  `@renderer/*` (web). Within `src/shared` and `src/domain`, relative imports are used.
- Renderers must **never** import `electron` or node built-ins. Only `window.dayly`.

---

## 1. Persistence — `src/main/db/`

### `connection.ts`

```ts
export function openDatabase(filePath: string): Database.Database
```

Opens with `PRAGMA journal_mode = WAL`, `foreign_keys = ON`, `busy_timeout = 5000`,
`synchronous = NORMAL`.

### `migrations.ts`

```ts
export const CURRENT_SCHEMA_VERSION: number
export function runMigrations(db: Database.Database): void
```

Version tracked in `schema_version(version INTEGER NOT NULL)`. Migrations are an ordered
array of `{ version, up(db) }`, applied inside a transaction, idempotent on re-run.

Schema v1:

```sql
CREATE TABLE days (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  date           TEXT    NOT NULL UNIQUE,          -- 'YYYY-MM-DD' local
  created_at     INTEGER NOT NULL,                 -- UTC epoch ms
  ended_at       INTEGER,                          -- NULL until End Day
  target_minutes INTEGER NOT NULL
);
CREATE TABLE segments (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  day_id     INTEGER NOT NULL REFERENCES days(id) ON DELETE CASCADE,
  type       TEXT    NOT NULL CHECK (type IN ('work','break')),
  started_at INTEGER NOT NULL,
  ended_at   INTEGER,                              -- NULL = open
  note       TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX idx_segments_day ON segments(day_id, started_at);
CREATE INDEX idx_segments_open ON segments(ended_at) WHERE ended_at IS NULL;
CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE schema_version (version INTEGER NOT NULL);
```

**No totals are ever stored.** Totals come from `@domain/duration`.

### `repository.ts`

```ts
export const APP_STATE_HEARTBEAT = 'heartbeat_at';

export class Repository {
  constructor(db: Database.Database);

  findDay(date: DateKey): Day | null;
  getOrCreateDay(date: DateKey, targetMinutes: number, now: EpochMs): Day;
  setDayEnded(dayId: number, endedAt: EpochMs | null): Day;
  /**
   * Re-stamp an existing day's target. `getOrCreateDay` only ever stamps at creation,
   * so this is the one path by which a changed preference reaches a day already under
   * way; callers pass only the day in progress, never a past one.
   */
  setDayTarget(dayId: number, targetMinutes: number): Day;

  listSegments(dayId: number): Segment[];              // ordered by started_at
  getDayDetail(date: DateKey, now?: EpochMs): DayDetail | null;
  getRange(range: DateRange, now?: EpochMs): DayDetail[];

  findOpenSegment(): Segment | null;                   // across every day
  insertSegment(input: {
    dayId: number; type: SegmentType; startedAt: EpochMs;
    endedAt: EpochMs | null; note?: string | null;
  }, now: EpochMs): Segment;
  updateSegmentFields(id: number, patch: {
    type?: SegmentType; startedAt?: EpochMs; endedAt?: EpochMs | null; note?: string | null;
  }, now: EpochMs): Segment;
  deleteSegment(id: number): boolean;
  getSegment(id: number): Segment | null;

  /**
   * Close `id` at `endedAt`, splitting at every local midnight it crosses via
   * `splitAtMidnight`. The original row becomes the first piece; later pieces are
   * inserted against their own days (created on demand with `targetMinutes`).
   * Returns every resulting piece, ordered.
   */
  closeSegmentSplitting(id: number, endedAt: EpochMs, targetMinutes: number, now: EpochMs): Segment[];

  getAppState(key: string): string | null;
  setAppState(key: string, value: string): void;

  transaction<T>(fn: () => T): T;
  close(): void;
}
```

`getDayDetail` / `getRange` build `DayTotals` with `dayTotals(segments, date, now)` from
`@domain/duration`. `getRange` returns only days that exist in the table, ascending.

Row → object mapping converts snake_case columns to the camelCase domain types, and
`better-sqlite3` returns are typed via explicit row interfaces (never `any`).

---

## 2. Preferences — `src/main/store/preferences.ts`

```ts
export const DEFAULT_PREFERENCES: Preferences;

export class PreferencesStore {
  /** Must be constructed after `app.whenReady()`. */
  constructor(platformDefaults: { showMiniWindow: boolean });
  getAll(): Preferences;
  get<K extends keyof Preferences>(key: K): Preferences[K];
  set<K extends keyof Preferences>(key: K, value: Preferences[K]): Preferences;
  reset(): Preferences;
  onChange(listener: (prefs: Preferences) => void): () => void;
}
```

Backed by `electron-store` (`new Store({ name: 'preferences', defaults })`). Values are
**clamped and validated** on write — `idleThresholdMinutes` 1–240, `dailyTargetHours`
0–24, `reminderHour` 0–23, `reminderMinute` 0–59, `weekStartsOn` 0|1. Unknown keys are
rejected. `showMiniWindow`'s default comes from `platformDefaults` (on for Windows/Linux,
off for macOS).

`launchAtLogin` is the one preference the store does **not** own outright: the system lets
the user change it too (macOS System Settings, the autostart file, the Run key), so startup
reconciles the stored value against `platform.isLoginItemEnabled()` and the **OS wins**.
Without that the toggle would go on claiming "on" after the user switched Dayly off in
System Settings, and the stale preference would silently re-register it on the next launch.

---

## 3. Platform abstraction — `src/main/platform/`

**All** `process.platform` branching in the entire codebase lives here. No other file may
test the platform.

### `Platform.ts`

```ts
export interface TrayView { state: TimerState; workedMs: number; breakMs: number }

export interface Platform {
  readonly os: OsKind;
  readonly supportsTrayTitle: boolean;
  readonly miniWindowDefaultOn: boolean;
  /** How often the tray label/tooltip is refreshed. mac 1000ms, win/linux 30000ms. */
  readonly trayRefreshIntervalMs: number;

  /** dock.hide(), app user model id, GTK hints — called once, before windows exist. */
  configureApp(): void;

  /** Probes whether a tray host actually exists (always true on mac/windows). */
  detectTrayAvailable(): Promise<boolean>;

  /** Absolute path to the tray image for a state. */
  trayImagePath(state: TimerState): string;

  /** Applies image + title + tooltip for the current view. */
  applyTray(tray: Tray, view: TrayView): void;

  /** Per-OS additions to the mini-window's constructor options. */
  miniWindowOptions(): Partial<BrowserWindowConstructorOptions>;
  /** Post-construction mini-window tweaks (levels, workspace visibility). */
  configureMiniWindow(win: BrowserWindow): void;

  /** Per-OS additions to the panel window's constructor options. */
  panelWindowOptions(): Partial<BrowserWindowConstructorOptions>;

  setLoginItemEnabled(enabled: boolean): Promise<void>;
  isLoginItemEnabled(): Promise<boolean>;

  revealInFileManager(target: string): Promise<void>;
}

export function createPlatform(): Platform;
```

### `MacPlatform.ts`

- `configureApp()` → `app.dock?.hide()`.
- `supportsTrayTitle = true`, `miniWindowDefaultOn = false`, `trayRefreshIntervalMs = 1000`.
- `applyTray` → template image (`nativeImage.setTemplateImage(true)`) plus
  `tray.setTitle(formatHM(workedMs))` while RUNNING/PAUSED, `tray.setTitle('')` when
  IDLE/ENDED. Paused shows the time in parentheses is **not** used; instead the icon
  changes and the title keeps showing the frozen total.
- `configureMiniWindow` → `setAlwaysOnTop(true, 'floating')`,
  `setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true })`.
- `setLoginItemEnabled` → `app.setLoginItemSettings({ openAtLogin })`. No `openAsHidden`:
  it is deprecated and ignored from macOS 13 on, where registration goes through
  `SMAppService`, and a login launch is silent anyway because `configureApp` hides the
  dock and no window opens at startup.
- `revealInFileManager` → `shell.showItemInFolder`.

### `WindowsPlatform.ts`

- `supportsTrayTitle = false`, `miniWindowDefaultOn = true`, `trayRefreshIntervalMs = 30000`.
- `configureApp()` → `app.setAppUserModelId('me.faizraza.dayly')`.
- `applyTray` → state-encoding `.ico` (idle/running/paused) + `tray.setToolTip(...)` with
  the live time, e.g. `Dayly — 6:24 worked · 0:45 break`.
- `miniWindowOptions()` → `{ skipTaskbar: true }`.
- `setLoginItemEnabled` → `app.setLoginItemSettings({ openAtLogin })`.

### `LinuxPlatform.ts`

- `supportsTrayTitle = false`, `miniWindowDefaultOn = true`, `trayRefreshIntervalMs = 30000`.
- `detectTrayAvailable()` → checks for a StatusNotifierItem host by looking for the
  `org.kde.StatusNotifierWatcher` / `org.freedesktop.StatusNotifierWatcher` DBus name via
  `gdbus`/`dbus-send` (whichever exists), with a short timeout. Any failure, missing tool,
  or missing `DISPLAY`/`WAYLAND_DISPLAY` resolves to `false`. Must never throw or hang.
- `applyTray` → PNG per state + `setToolTip`.
- `miniWindowOptions()` → `{ type: 'utility' }`.
- Autostart: writes/removes `~/.config/autostart/dayly.desktop` with
  `Type=Application`, `Name=Dayly`, `Exec=<execPath> --hidden`, `X-GNOME-Autostart-enabled=true`.
  Uses `process.env.APPIMAGE ?? app.getPath('exe')` for `Exec`.
- `revealInFileManager` → `shell.openPath(dirname)` (showItemInFolder is unreliable).

### `trayIcons.ts`

Resolves icon paths for dev (`resources/`) and packaged (`process.resourcesPath`) builds.

---

## 4. Services — `src/main/services/`

### `TimerService.ts` — the state machine, the only writer of timer segments

```ts
export class TimerService {
  constructor(deps: {
    repo: Repository;
    prefs: PreferencesStore;
    now?: () => EpochMs;   // injectable for tests
  });

  getSnapshot(now?: EpochMs): TimerSnapshot;
  start(): TimerSnapshot;
  pause(): TimerSnapshot;
  resume(): TimerSnapshot;
  endDay(): TimerSnapshot;

  /** Applies a `RecoveryPlan` from `@domain/recovery`. */
  applyRecovery(plan: RecoveryPlan): TimerSnapshot;
  /** Applies an `IdlePlan`. */
  applyIdle(plan: IdlePlan): TimerSnapshot;
  /** Closes the open work segment at `at` because the machine slept/locked. */
  suspendAt(at: EpochMs): void;
  /** Applies a `WakePlan`. */
  applyWake(plan: WakePlan): TimerSnapshot;

  /** Splits the open segment if it has run past local midnight. Idempotent. */
  rollOverMidnight(now?: EpochMs): TimerSnapshot;

  /**
   * Re-stamps the day in progress from `dailyTargetHours`, returning the dates that
   * changed (empty when the row does not exist yet or already matches). Emits nothing:
   * the caller announces the change it already knows about.
   */
  syncTodayTarget(): DateKey[];

  onSnapshot(listener: (snapshot: TimerSnapshot) => void): () => void;
  /** Emits the current snapshot to listeners. */
  emit(): TimerSnapshot;
}
```

State derivation (never stored as a column — always derived, so it survives a crash):

- open segment of type `work` → `RUNNING`
- open segment of type `break` → `PAUSED`
- no open segment, today's `day.endedAt !== null` → `ENDED`
- otherwise → `IDLE`

Transitions:

- `start()` from IDLE/ENDED → `getOrCreateDay(today)`, clear `day.endedAt`, open a `work` segment at now.
- `pause()` from RUNNING → close the work segment (via `closeSegmentSplitting`), open a `break` segment at the same instant.
- `resume()` from PAUSED → close the break segment, open a `work` segment at the same instant.
- `endDay()` from RUNNING/PAUSED → close the open segment, set `day.endedAt = now`.
- Every transition is wrapped in `repo.transaction`, then `emit()`.
- Calling a transition from a state that does not allow it is a no-op that returns the
  current snapshot (never throws) — the UI disables the buttons anyway.

`getSnapshot` fills `closedWorkedMs`/`closedBreakMs` from **closed** segments on today's
date only, plus `openSegment`, so renderers compute the live value themselves.

### `HeartbeatService.ts`

```ts
export class HeartbeatService {
  constructor(repo: Repository, intervalMs?: number /* default 30_000 */);
  start(): void;   // begins writing APP_STATE_HEARTBEAT
  stop(): void;
  writeNow(): void;
}
```

Runs only while a segment is open. Also written on `before-quit`.

### `IdleMonitor.ts`

```ts
export class IdleMonitor {
  constructor(deps: { prefs: PreferencesStore; onIdleDetected: (idleStartedAt: EpochMs, idleMs: EpochMs) => void });
  start(): void;
  stop(): void;
  /** Call whenever the timer state changes; monitoring only runs while RUNNING. */
  setRunning(running: boolean): void;
}
```

Polls `powerMonitor.getSystemIdleTime()` (seconds) every 15s. Fires **once** per idle
stretch when the threshold is crossed, and re-arms only after the user is active again.

### `PowerMonitorService.ts`

```ts
export class PowerMonitorService {
  constructor(deps: {
    prefs: PreferencesStore;
    onAway: (at: EpochMs, reason: WakeReason) => void;
    onBack: (awayAt: EpochMs, backAt: EpochMs, reason: WakeReason) => void;
  });
  start(): void;
  stop(): void;
}
```

Wires `suspend`/`resume` and `lock-screen`/`unlock-screen`. Respects
`autoPauseOnSleep` / `autoPauseOnLock`. Collapses a lock-then-suspend pair into one gap.

### `ReminderService.ts`

```ts
export class ReminderService {
  constructor(deps: { prefs: PreferencesStore; isRunning: () => boolean; onRemind: () => void });
  start(): void;
  stop(): void;
}
```

Checks each minute; fires at most once per calendar day when local time passes
`reminderHour:reminderMinute` and the timer is still RUNNING.

### `ExportService.ts`

```ts
export function buildCsv(days: readonly DayDetail[]): string;
export function buildJson(days: readonly DayDetail[], range: DateRange): string;
```

CSV columns: `date,segment_type,started_at_local,ended_at_local,duration_minutes,started_at_utc_ms,ended_at_utc_ms,note`.
Fields containing `,` `"` or newlines are quoted with `""` escaping. A day with no
segments still emits one row with empty segment fields. JSON is
`{ exportedAt, range, days: [{ date, targetMinutes, totals, segments }] }`, pretty-printed.

### `BackupService.ts`

```ts
export async function backupDatabase(dbPath: string, parent: BrowserWindow | null): Promise<FileWriteResult>;
```

`dialog.showSaveDialog` defaulting to `dayly-backup-YYYY-MM-DD.sqlite`, then
`db.backup(dest)` via better-sqlite3's online backup API (safe while WAL is active).

---

## 5. Windows — `src/main/windows/WindowManager.ts`

```ts
export class WindowManager {
  constructor(deps: { platform: Platform; prefs: PreferencesStore });
  get(kind: WindowKind): BrowserWindow | null;
  open(kind: WindowKind): BrowserWindow;
  close(kind: WindowKind): void;
  toggle(kind: WindowKind): void;
  /** Positions and shows the panel next to the tray icon. */
  togglePanelNearTray(trayBounds: Rectangle | null): void;
  /** Creates/destroys the mini-window to match the preference. */
  syncMiniWindow(show: boolean): void;
  /** Persists the mini-window position keyed by the display it sits on. */
  rememberMiniPosition(): void;
  broadcast<T>(channel: EventChannel, payload: T): void;
  destroyAll(): void;
}
```

Common `webPreferences` for every window:

```ts
{ preload: join(__dirname, '../preload/index.js'), contextIsolation: true,
  nodeIntegration: false, sandbox: true, webSecurity: true }
```

Loading a window: in dev use `process.env.ELECTRON_RENDERER_URL` +
`/<kind>.html`; in production `loadFile(join(__dirname, '../renderer/<kind>.html'))`.

Window shapes:

| kind | size | frame | resizable | notes |
|---|---|---|---|---|
| `panel` | 340×470 | frameless | no | `show: false`, hides on blur, `skipTaskbar: true` |
| `mini` | 180×56 | frameless, transparent | no | always-on-top, draggable, per-display position |
| `history` | 980×680 (min 760×520) | standard | yes | normal window, appears in taskbar/dock |
| `settings` | 560×720 (min 480×560) | standard | yes | normal window |

`history` and `settings` are the only windows that show in the taskbar. When they open,
macOS must call `app.dock?.show()`; when the last of them closes, `app.dock?.hide()`.

Mini-window position: on move, find the display containing the window via
`screen.getDisplayMatching(bounds)` and store `prefs.miniWindowPositions[String(display.id)]`.
On create, restore for the current display, and clamp into the display's work area.
If no stored position, place it 24px from the top-right of the primary work area.

---

## 6. Tray — `src/main/tray/TrayController.ts`

```ts
export class TrayController {
  constructor(deps: {
    platform: Platform;
    timer: TimerService;
    prefs: PreferencesStore;
    onTogglePanel: (bounds: Rectangle | null) => void;
    onOpen: (kind: WindowKind) => void;
    onQuit: () => void;
  });
  /** Returns false when no tray host exists (Linux fallback). */
  init(): Promise<boolean>;
  refresh(): void;
  destroy(): void;
}
```

Builds the context menu (Start/Pause/Resume, End Day, separator, Open Dayly, History,
Settings, separator, Quit), rebuilding it whenever the timer state changes. Left click
toggles the panel; on Windows/Linux the context menu is bound to right click. Refresh is
driven by `platform.trayRefreshIntervalMs`, and additionally on every snapshot change.

---

## 7. IPC — `src/main/ipc/handlers.ts`

```ts
export function registerIpcHandlers(deps: {
  repo: Repository;
  timer: TimerService;
  prefs: PreferencesStore;
  windows: WindowManager;
  platform: Platform;
  dbPath: string;
  getPendingRecovery: () => PendingRecovery | null;
  resolveRecovery: (choice: RecoveryChoice) => TimerSnapshot;
  resolveIdle: (promptId: string, choice: IdleChoice) => TimerSnapshot;
  resolveWake: (promptId: string, choice: WakeChoice) => TimerSnapshot;
  platformInfo: () => PlatformInfo;
  /** Applies the OS login item. Rejects when the OS refuses; the caller must not persist then. */
  setLoginItemEnabled: (enabled: boolean) => Promise<void>;
}): void;
```

One `ipcMain.handle` per `INVOKE` channel, each returning exactly the type declared on
`DaylyApi`. Handlers **validate every argument** — they are the trust boundary — and
never throw across the bridge: failures become `{ ok: false, code, message }`.

`prefs:set` is the single deliberate exception, because its contract has nowhere to put a
failure: every value it could fall back to is a set of preferences the renderer assigns to
state and reports as saved, so a write that did not happen **rejects** instead. Reads stay
asymmetric — `prefs:get-all` still falls back to the defaults, since a window handed
nothing cannot render at all. A read that lies is a wrong screen; a write that lies is lost
data. `launchAtLogin` is written OS-first: `setLoginItemEnabled` is awaited and the
preference is stored only if the OS accepted it.

Segment mutations use `validateSegment` from `@domain/overlap` against the day's other
segments, apply `splitAtMidnight` when an edit stretches across a boundary, run in a
transaction, then broadcast `EVENT.historyInvalidated` and a fresh snapshot.

---

## 8. Preload — `src/preload/index.ts`

Implements `DaylyApi` exactly and exposes it via
`contextBridge.exposeInMainWorld('dayly', api)`. Rules:

- `windowKind` is parsed from `location.pathname` (`/panel.html` → `panel`), defaulting
  to `panel`.
- Every `on*` returns an `Unsubscribe` that calls `ipcRenderer.removeListener`.
- Listener callbacks receive **only** the payload, never the `IpcRendererEvent`.
- Only channels in `ALL_INVOKE_CHANNELS` / `ALL_EVENT_CHANNELS` are reachable.
- No node API, no `remote`, nothing else on `window`.

---

## 9. Main entry — `src/main/index.ts`

Ordered startup:

1. `app.requestSingleInstanceLock()`; if not acquired, `app.quit()`. On
   `second-instance`, open/focus the panel.
2. `app.whenReady()`.
3. `createPlatform()` → `platform.configureApp()`.
4. `PreferencesStore` with `{ showMiniWindow: platform.miniWindowDefaultOn }`.
5. Open DB at `join(app.getPath('userData'), 'dayly.sqlite')`, `runMigrations`.
6. Apply a CSP via `session.defaultSession.webRequest.onHeadersReceived`:
   production `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'none'`;
   in dev additionally allow the Vite dev server origin and `ws:` for HMR.
   Also deny all permission requests via `setPermissionRequestHandler`.
7. Crash recovery: `repo.findOpenSegment()`; if found build a `PendingRecovery` with the
   stored heartbeat. If `isRecoveryWorthPrompting` is false, discard silently. Otherwise
   hold it, open the panel and broadcast `EVENT.recoveryPrompt`.
8. `TimerService`, `HeartbeatService`, `IdleMonitor`, `PowerMonitorService`,
   `ReminderService`, `WindowManager`, `TrayController`, `registerIpcHandlers`.
9. If `tray.init()` returns false → force `showMiniWindow` on, and if
   `trayFallbackNoticeShown` is false, broadcast a `Notice` and set the flag.
10. A 1s interval calls `timer.rollOverMidnight()` so a running segment splits at midnight
    even with no user interaction; broadcast the snapshot on change.
11. `app.on('window-all-closed')` → **do not quit** (tray app). Quit only via the tray
    menu or `INVOKE.systemQuit`, which sets a `quitting` flag so windows really close.
12. On `before-quit`: write the heartbeat, stop services, `repo.close()`.

Notifications for idle/wake prompts use Electron's `Notification` and also surface in the
panel UI, so a dismissed notification is never the only way to answer.

---

## 10. Renderer

Four independent React roots, one per window, all rendered with `createRoot`.

### Shared — `src/renderer/src/`

- `styles.css` — the single Tailwind v4 entry: `@import "tailwindcss";` plus a
  `@theme` block and the dark-mode variant. Imported by every window entry.
- `lib/api.ts` — `export const api = window.dayly;` plus small typed helpers.
- `hooks/useTicker.ts` — `useTicker(intervalMs = 1000): number` returning `Date.now()`,
  driven by `setInterval`; also re-reads on `visibilitychange` so a hidden window catches
  up immediately when shown.
- `hooks/useSnapshot.ts` — subscribes to `api.timer.onSnapshot`, seeds from
  `getSnapshot()`, returns `{ snapshot, live }` where `live = liveTotals(snapshot, tick)`.
- `hooks/usePrefs.ts` — `{ prefs, setPref }` backed by `api.prefs`.
- `components/` — `TimerDisplay`, `ActionButton`, `SegmentRow`, `ProgressBar`,
  `Button`, `Toggle`, `NumberField`, `Modal`, `EmptyState`.

The primary action is derived from state: IDLE/ENDED → `Start`, RUNNING → `Pause`,
PAUSED → `Resume`. `End Day` renders only when the state is RUNNING or PAUSED.

**All elapsed values come from `liveTotals(snapshot, tick)`** — never from a counter.

### `panel/` (340×470)

Big `H:MM:SS` worked timer, break line, progress toward the daily target, primary action,
End Day, today's segment list, footer links to History and Settings. Hosts the recovery,
idle and wake prompt modals, and the notice banner.

### `mini/` (180×56)

`H:MM` timer plus one icon action button. The whole surface is
`-webkit-app-region: drag` except the button, which must be `no-drag`. Reports its
position through `api.windows.reportMiniMoved` on drag end (`mouseup` + a `resize`/`move`
safety net).

### `history/` (980×680)

Month calendar grid (worked total per day, target-met marker) with a list-view toggle,
week/month totals and the daily average, click-to-expand day detail with its segments,
manual add/edit/delete of segments with validation errors surfaced from the
`MutationResult`, and CSV/JSON export buttons for the visible range.

### `settings/` (560×720)

Every preference in `Preferences`, grouped: General (launch at login, mini-window,
theme, week start), Tracking (daily target, idle detection + threshold, auto-pause on
sleep/lock), Reminders (enabled, time), Data (folder path, reveal button, backup button).
Changes save immediately.

---

## 11. Icons — `scripts/generate-icons.mjs`

Pure Node (zlib + manual PNG/ICO encoding, no dependencies). Generates:

- `build/icon.png` — 1024×1024 app icon (electron-builder derives `.icns`/`.ico`).
- `resources/tray/mac/trayTemplate.png` + `@2x` — black-on-transparent template icons.
- `resources/tray/win/{idle,running,paused}.ico` — 16/24/32px, colour-coded per state.
- `resources/tray/linux/{idle,running,paused}.png` — 22/24/32px.

The three states must be distinguishable by **shape**, not just colour (idle = hollow
ring, running = filled ring, paused = ring with a pause bar), because on Windows the icon
is the only state indicator.

---

## 12. Renderer shared API (binding — the four window UIs code against this)

`src/renderer/src/lib/api.ts`

```ts
export const api: DaylyApi;                       // = window.dayly
export function mountWindow(node: ReactNode): void;  // createRoot(#root).render(<StrictMode>…)
export function cn(...parts: Array<string | false | null | undefined>): string;
```

`src/renderer/src/hooks/`

```ts
// useTicker.ts
export function useTicker(intervalMs?: number): number;   // default 1000, returns Date.now()

// useSnapshot.ts
export interface SnapshotState { snapshot: TimerSnapshot | null; live: LiveTotals; tick: number }
export function useSnapshot(): SnapshotState;

// usePrefs.ts
export interface PrefsState {
  prefs: Preferences | null;
  setPref: <K extends keyof Preferences>(key: K, value: Preferences[K]) => Promise<void>;
}
export function usePrefs(): PrefsState;

// usePlatformInfo.ts
export function usePlatformInfo(): PlatformInfo | null;
```

`src/renderer/src/components/` — props are exact:

```ts
// Button.tsx
export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';
export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant; size?: 'sm' | 'md' | 'lg';
}
export function Button(props: ButtonProps);

// Toggle.tsx
export interface ToggleProps {
  checked: boolean; onChange: (next: boolean) => void;
  label: string; description?: string; disabled?: boolean;
}
export function Toggle(props: ToggleProps);

// NumberField.tsx
export interface NumberFieldProps {
  value: number; onChange: (next: number) => void; label: string;
  min?: number; max?: number; step?: number;
  description?: string; suffix?: string; disabled?: boolean;
}
export function NumberField(props: NumberFieldProps);

// ProgressBar.tsx
export interface ProgressBarProps { progress: number; className?: string }
export function ProgressBar(props: ProgressBarProps);   // clamps 0..1, shows overflow tint past 1

// TimerDisplay.tsx
export interface TimerDisplayProps { ms: number; withSeconds?: boolean; className?: string }
export function TimerDisplay(props: TimerDisplayProps);  // tabular-nums

// ActionButton.tsx
export interface ActionButtonProps {
  state: TimerState; compact?: boolean; disabled?: boolean;
  onStart: () => void; onPause: () => void; onResume: () => void;
}
export function ActionButton(props: ActionButtonProps);

// SegmentRow.tsx
export interface SegmentRowProps {
  segment: Segment; now: number;
  onEdit?: (segment: Segment) => void;
  onDelete?: (segment: Segment) => void;
}
export function SegmentRow(props: SegmentRowProps);

// Modal.tsx
export interface ModalProps {
  open: boolean; title: string; children: ReactNode;
  footer?: ReactNode; onClose?: () => void;
}
export function Modal(props: ModalProps);

// EmptyState.tsx
export interface EmptyStateProps { title: string; description?: string }
export function EmptyState(props: EmptyStateProps);
```

Do **not** annotate component return types as `JSX.Element` (there is no global `JSX`
namespace under `jsx: react-jsx` with `types: []`); let the return type be inferred.

Each window entry is `src/renderer/src/<kind>/main.tsx`, which imports
`../styles.css`, builds its root component and calls `mountWindow(<App />)`.

## 13. Visual design

Dark-first, calm, native-feeling. Tailwind v4 with a `@theme` block; use CSS variables
for surface/text/accent so light and dark both work, driven by the `theme` preference
(`system` follows `prefers-color-scheme`, applied by toggling a `dark` class on `<html>`).

- Accent: a single restrained indigo/violet for the primary action and progress fill.
- Work segments read green-ish, break segments amber-ish, at low saturation.
- Numerals are `tabular-nums` everywhere a value ticks, so nothing jitters.
- The panel and mini windows are frameless: give them rounded corners and a subtle
  border, and no text selection (`select-none`) except in inputs.

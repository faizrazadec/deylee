/**
 * Every BrowserWindow the app owns, and the rules for where each one sits.
 *
 * Four windows, four jobs: `panel` is a tray popover, `mini` is an always-on-top
 * readout, `history` and `settings` are ordinary documents. Only the last two are
 * real "app" windows, which is why they alone drive the dock.
 *
 * Windows are held in a map keyed by kind so a second `open` reuses the live one;
 * the map entry is dropped on `closed`, which is the only signal that survives both
 * a user close and a `destroy()`.
 */

import { join } from 'node:path';
import { app, BrowserWindow, screen } from 'electron';
import type {
  BrowserWindowConstructorOptions,
  Display,
  Rectangle,
  WebPreferences,
} from 'electron';
import type { EventChannel } from '@shared/ipc';
import type { MiniWindowPosition, WindowKind } from '@shared/types';
import type { Platform } from '@main/platform/Platform';
import type { PreferencesStore } from '@main/store/preferences';

/**
 * The security posture of every window. Applied last when constructing, so no
 * per-OS option block can weaken it by accident.
 */
const WEB_PREFERENCES: WebPreferences = {
  preload: join(__dirname, '../preload/index.js'),
  contextIsolation: true,
  nodeIntegration: false,
  sandbox: true,
  webSecurity: true,
};

const MINI_SIZE = { width: 180, height: 56 } as const;

/** Distance from the top-right of the work area for a mini-window with no stored spot. */
const MINI_DEFAULT_INSET = 24;

/**
 * A drag emits a stream of `move` events on Windows and Linux; only where the
 * window comes to rest is worth a write to disk.
 */
const MINI_MOVE_DEBOUNCE_MS = 300;

/** Breathing room between the tray icon and the panel's edge. */
const PANEL_TRAY_GAP = 8;

/** The only kinds that belong in the taskbar/dock. */
const TASKBAR_KINDS: readonly WindowKind[] = ['history', 'settings'];

function clampInto(value: number, min: number, max: number): number {
  // `min` wins when the window is larger than the area, which beats pushing it
  // off the top-left corner.
  return Math.max(min, Math.min(value, max));
}

function hasArea(rect: Rectangle): boolean {
  return rect.width > 0 && rect.height > 0;
}

function centreIn(area: Rectangle, width: number, height: number): Rectangle {
  return {
    x: Math.round(area.x + (area.width - width) / 2),
    y: Math.round(area.y + (area.height - height) / 2),
    width,
    height,
  };
}

/**
 * Reads a remembered position for a display. The preferences file is plain JSON on
 * disk, so a hand-edited or partially written entry must not place a window at NaN.
 */
function readStoredPosition(
  positions: Record<string, MiniWindowPosition>,
  displayId: number,
): MiniWindowPosition | null {
  const stored: MiniWindowPosition | undefined = positions[String(displayId)];
  if (stored === undefined) return null;
  if (!Number.isFinite(stored.x) || !Number.isFinite(stored.y)) return null;
  return stored;
}

export class WindowManager {
  private readonly platform: Platform;
  private readonly prefs: PreferencesStore;
  private readonly windows = new Map<WindowKind, BrowserWindow>();
  private panelVisibility: ((visible: boolean) => void) | null = null;
  private miniMoveTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(deps: { platform: Platform; prefs: PreferencesStore }) {
    this.platform = deps.platform;
    this.prefs = deps.prefs;
  }

  /**
   * Registers the listener that tracks whether the panel is on screen. macOS uses it
   * to hold the menu-bar selection highlight for exactly as long as the panel is up.
   */
  onPanelVisibility(listener: (visible: boolean) => void): void {
    this.panelVisibility = listener;
  }

  get(kind: WindowKind): BrowserWindow | null {
    const win = this.windows.get(kind);
    return win !== undefined && !win.isDestroyed() ? win : null;
  }

  open(kind: WindowKind): BrowserWindow {
    const existing = this.get(kind);
    if (existing !== null) {
      this.reveal(kind, existing);
      return existing;
    }
    const win = this.createWindow(kind);
    this.showWhenReady(kind, win);
    return win;
  }

  close(kind: WindowKind): void {
    const win = this.get(kind);
    if (win === null) return;
    if (kind === 'panel') {
      // The panel is a popover, not a document: putting it away keeps its renderer
      // warm so the next tray click is instant.
      win.hide();
      return;
    }
    this.teardown(kind, win);
  }

  toggle(kind: WindowKind): void {
    const win = this.get(kind);
    if (win !== null && win.isVisible()) {
      this.close(kind);
      return;
    }
    this.open(kind);
  }

  togglePanelNearTray(trayBounds: Rectangle | null): void {
    const existing = this.get('panel');
    if (existing !== null && existing.isVisible()) {
      existing.hide();
      return;
    }
    const win = existing ?? this.createWindow('panel');
    this.positionPanel(win, trayBounds);
    this.showWhenReady('panel', win);
  }

  syncMiniWindow(show: boolean): void {
    const existing = this.get('mini');
    if (show) {
      if (existing === null) this.open('mini');
      return;
    }
    if (existing !== null) this.teardown('mini', existing);
  }

  rememberMiniPosition(): void {
    const win = this.get('mini');
    if (win === null) return;
    const bounds = win.getBounds();
    const displayId = screen.getDisplayMatching(bounds).id;
    // Merge, never replace: every other display keeps the spot the user chose for it.
    this.prefs.set('miniWindowPositions', {
      ...this.prefs.get('miniWindowPositions'),
      [String(displayId)]: { x: bounds.x, y: bounds.y },
    });
  }

  broadcast<T>(channel: EventChannel, payload: T): void {
    for (const win of this.windows.values()) {
      if (win.isDestroyed() || win.webContents.isDestroyed()) continue;
      win.webContents.send(channel, payload);
    }
  }

  destroyAll(): void {
    this.flushMiniPosition();
    for (const [kind, win] of [...this.windows]) {
      this.windows.delete(kind);
      if (!win.isDestroyed()) win.destroy();
    }
  }

  /* ------------------------------------------------------------------------ */
  /* Construction                                                              */
  /* ------------------------------------------------------------------------ */

  private createWindow(kind: WindowKind): BrowserWindow {
    const win = new BrowserWindow({
      ...this.optionsFor(kind),
      webPreferences: { ...WEB_PREFERENCES },
    });
    this.windows.set(kind, win);
    win.on('closed', () => {
      this.forget(kind, win);
    });

    if (kind === 'panel') {
      win.on('blur', () => {
        // Clicking into the panel's own devtools blurs it too; dismissing then
        // would make the panel impossible to inspect.
        if (win.webContents.isDevToolsFocused()) return;
        win.hide();
      });
      // Driven by the window's own events rather than by the toggle call, so a
      // dismiss-on-blur clears the tray highlight just as reliably as an explicit
      // close does.
      win.on('show', () => this.panelVisibility?.(true));
      win.on('hide', () => this.panelVisibility?.(false));
      win.on('closed', () => this.panelVisibility?.(false));
      // A sane default until a tray click supplies real anchor bounds.
      this.positionPanel(win, null);
    }

    if (kind === 'mini') {
      this.platform.configureMiniWindow(win);
      const onMove = (): void => {
        this.scheduleMiniPosition();
      };
      win.on('move', onMove);
      win.on('moved', onMove);
    }

    if (TASKBAR_KINDS.includes(kind)) this.syncDock();

    this.load(win, kind);
    return win;
  }

  private optionsFor(kind: WindowKind): BrowserWindowConstructorOptions {
    switch (kind) {
      case 'panel':
        return {
          // docs/DESIGN.md §4: 320 wide with a 284px content column inside 18px padding.
          // Height is content-driven between 372 and 436; 436 is the tallest state
          // (running, with a full segment list).
          width: 320,
          height: 436,
          frame: false,
          resizable: false,
          skipTaskbar: true,
          show: false,
          ...this.platform.panelWindowOptions(),
        };

      case 'mini': {
        const position = this.resolveMiniPosition();
        return {
          width: MINI_SIZE.width,
          height: MINI_SIZE.height,
          x: position.x,
          y: position.y,
          frame: false,
          transparent: true,
          resizable: false,
          alwaysOnTop: true,
          show: false,
          ...this.platform.miniWindowOptions(),
        };
      }

      case 'history':
        return {
          // docs/DESIGN.md §6. The minimum keeps the 352px detail column plus a
          // legible seven-column calendar beside it.
          width: 900,
          height: 640,
          minWidth: 760,
          minHeight: 520,
          resizable: true,
          show: false,
        };

      case 'settings':
        return {
          // docs/DESIGN.md §7 specifies 560 × 480, but that spec covers only four of
          // the required preference groups. The rest (sleep/lock auto-pause, the
          // reminder, week start, backup) push past 480, so the window keeps the
          // specified width and scrolls instead of growing indefinitely.
          width: 560,
          height: 640,
          minWidth: 480,
          minHeight: 420,
          resizable: true,
          show: false,
        };
    }
  }

  private load(win: BrowserWindow, kind: WindowKind): void {
    const devServer = process.env.ELECTRON_RENDERER_URL;
    const loading =
      devServer !== undefined && devServer.length > 0
        ? win.loadURL(`${devServer}/${kind}.html`)
        : win.loadFile(join(__dirname, `../renderer/${kind}.html`));

    // A failed load leaves a blank window; it must not surface as an unhandled
    // rejection and take the main process down with it.
    loading.catch((error: unknown) => {
      console.error(`[dayly] failed to load the ${kind} window`, error);
    });
  }

  /* ------------------------------------------------------------------------ */
  /* Showing and tearing down                                                  */
  /* ------------------------------------------------------------------------ */

  /** Shows after the first paint for a window that is still loading, so nothing flashes. */
  private showWhenReady(kind: WindowKind, win: BrowserWindow): void {
    if (win.webContents.isLoadingMainFrame()) {
      win.once('ready-to-show', () => {
        this.reveal(kind, win);
      });
      return;
    }
    this.reveal(kind, win);
  }

  private reveal(kind: WindowKind, win: BrowserWindow): void {
    if (win.isDestroyed()) return;
    if (win.isMinimized()) win.restore();
    if (kind === 'mini') {
      // A passive readout must never steal focus from whatever is being worked on.
      win.showInactive();
      return;
    }
    win.show();
    win.focus();
  }

  private teardown(kind: WindowKind, win: BrowserWindow): void {
    // `destroy()` skips the `close` event, so anything owing a last write has to
    // happen here while the window still has bounds to read.
    if (kind === 'mini') this.flushMiniPosition();
    win.destroy();
  }

  private forget(kind: WindowKind, win: BrowserWindow): void {
    // Only drop the entry if it is still this window: a rapid close/open pair can
    // have already registered the replacement.
    if (this.windows.get(kind) === win) this.windows.delete(kind);
    if (kind === 'mini') this.cancelMiniPosition();
    if (TASKBAR_KINDS.includes(kind)) this.syncDock();
  }

  /**
   * `app.dock` exists only on macOS, so the optional call is also the platform
   * check — everywhere else this is a no-op.
   */
  private syncDock(): void {
    const anyOpen = TASKBAR_KINDS.some((kind) => this.get(kind) !== null);
    if (anyOpen) void app.dock?.show();
    else app.dock?.hide();
  }

  /* ------------------------------------------------------------------------ */
  /* Placement                                                                 */
  /* ------------------------------------------------------------------------ */

  private positionPanel(win: BrowserWindow, trayBounds: Rectangle | null): void {
    const { width, height } = win.getBounds();
    const area = this.displayForPanel(trayBounds).workArea;

    // Some tray hosts (notably Linux) report no geometry at all; with nothing to
    // anchor to, centring beats pinning the panel to a corner.
    if (trayBounds === null || !hasArea(trayBounds)) {
      win.setBounds(centreIn(area, width, height));
      return;
    }

    const below = Math.round(trayBounds.y + trayBounds.height + PANEL_TRAY_GAP);
    // A tray in the bottom half of the screen — the Windows notification area —
    // has no room underneath, so the panel opens upwards from the icon instead.
    const y = below + height <= area.y + area.height
      ? below
      : Math.round(trayBounds.y - height - PANEL_TRAY_GAP);

    win.setBounds({
      x: clampInto(
        Math.round(trayBounds.x + trayBounds.width / 2 - width / 2),
        area.x,
        area.x + area.width - width,
      ),
      y: clampInto(y, area.y, area.y + area.height - height),
      width,
      height,
    });
  }

  private displayForPanel(trayBounds: Rectangle | null): Display {
    if (trayBounds === null) return screen.getPrimaryDisplay();
    if (hasArea(trayBounds)) return screen.getDisplayMatching(trayBounds);
    return screen.getDisplayNearestPoint({ x: trayBounds.x, y: trayBounds.y });
  }

  private resolveMiniPosition(): MiniWindowPosition {
    const positions = this.prefs.get('miniWindowPositions');
    const primary = screen.getPrimaryDisplay();
    // Prefer the primary display's remembered spot, then any other display that is
    // still attached: a position saved on a monitor that has since been unplugged
    // would put the window somewhere the user cannot reach it.
    const candidates = [primary, ...screen.getAllDisplays().filter((d) => d.id !== primary.id)];

    for (const display of candidates) {
      const stored = readStoredPosition(positions, display.id);
      if (stored === null) continue;
      const area = display.workArea;
      return {
        x: clampInto(Math.round(stored.x), area.x, area.x + area.width - MINI_SIZE.width),
        y: clampInto(Math.round(stored.y), area.y, area.y + area.height - MINI_SIZE.height),
      };
    }

    const area = primary.workArea;
    return {
      x: area.x + area.width - MINI_SIZE.width - MINI_DEFAULT_INSET,
      y: area.y + MINI_DEFAULT_INSET,
    };
  }

  private scheduleMiniPosition(): void {
    if (this.miniMoveTimer !== null) clearTimeout(this.miniMoveTimer);
    this.miniMoveTimer = setTimeout(() => {
      this.miniMoveTimer = null;
      this.rememberMiniPosition();
    }, MINI_MOVE_DEBOUNCE_MS);
  }

  /** Writes a pending position immediately, for when the window is about to go away. */
  private flushMiniPosition(): void {
    if (this.miniMoveTimer === null) return;
    clearTimeout(this.miniMoveTimer);
    this.miniMoveTimer = null;
    this.rememberMiniPosition();
  }

  private cancelMiniPosition(): void {
    if (this.miniMoveTimer === null) return;
    clearTimeout(this.miniMoveTimer);
    this.miniMoveTimer = null;
  }
}

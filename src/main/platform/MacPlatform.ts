import { app, nativeImage, powerMonitor, shell, Tray } from 'electron';
import type { BrowserWindow, BrowserWindowConstructorOptions, NativeImage } from 'electron';
import { formatHM, MS_PER_SECOND } from '@shared/time';
import type { OsKind, TimerState } from '@shared/types';
import type { Platform, TrayView } from './Platform';
import type { TrayHost, TrayHostCallbacks } from './TrayHost';
import { ElectronTrayHost } from './TrayHost';
import { MacStatusItemHost } from './MacStatusItemHost';
import { formatTrayTooltip, macTrayIconPath } from './trayIcons';

/**
 * macOS: a menu-bar app. The icon is a template image that follows the system's
 * light/dark menu bar, and the live total is drawn as text beside it, which is what
 * every native time tracker on this platform does.
 */
export class MacPlatform implements Platform {
  readonly os: OsKind = 'darwin';
  readonly supportsTrayTitle = true;
  /** The menu-bar title already shows the running total, so the widget is redundant. */
  readonly miniWindowDefaultOn = false;
  /** The title is a live clock; anything slower than 1s visibly stutters. */
  readonly trayRefreshIntervalMs = 1_000;

  /** macOS reports screen lock and unlock to Electron. */
  readonly supportsLockDetection = true;

  /**
   * Squirrel.Mac refuses to install a bundle that is not signed *and* notarised, and
   * Dayly ships neither — there is no Apple Developer ID behind it. A self-update
   * would therefore download happily and then fail at the install step, which is the
   * worst possible moment to find out. Saying so up front and linking to the Releases
   * page is the honest version.
   */
  readonly supportsAutoUpdate = false;

  readonly autoUpdateBlockedReason =
    'Automatic updates need a signed build — check the Releases page.';

  readonly releasesUrl = 'https://github.com/faizrazadec/dayly/releases';

  /**
   * Only true once the native status item has actually loaded. A checkout built
   * without the Command Line Tools falls back to Electron's Tray, which cannot hold
   * the highlight — and the UI must not claim a capability the fallback lacks.
   */
  get supportsTrayHighlight(): boolean {
    return this.usingNativeItem;
  }

  private usingNativeItem = false;

  /** One image serves every state, so it is read from disk once. */
  private template: NativeImage | null = null;

  configureApp(): void {
    // Accessory app: no dock icon while only the tray, panel and mini-window exist.
    // WindowManager calls `dock.show()` again when History or Settings opens.
    app.dock?.hide();
  }

  async detectTrayAvailable(): Promise<boolean> {
    return true;
  }

  trayImagePath(_state: TimerState): string {
    return macTrayIconPath();
  }

  /**
   * Prefers the natively-owned status item, purely so the selection highlight can be
   * held while the panel is open — Electron's Tray lost that in v7. Falls back to the
   * Tray when the addon is not present, which costs the highlight and nothing else.
   */
  createTrayHost(callbacks: TrayHostCallbacks): TrayHost | null {
    const native = MacStatusItemHost.load(callbacks);
    if (native !== null) {
      this.usingNativeItem = true;
      return native;
    }
    this.usingNativeItem = false;
    const tray = new Tray(this.templateImage());
    return new ElectronTrayHost(tray, { mode: 'popup', supportsTitle: true, callbacks });
  }

  applyTray(host: TrayHost, view: TrayView): void {
    host.setImage(macTrayIconPath(), true);

    // Only a live session gets a title: an idle menu bar stays quiet, and the
    // paused total is frozen rather than hidden so the user still sees the day.
    const showsTotal = view.state === 'RUNNING' || view.state === 'PAUSED';
    host.setTitle(showsTotal ? formatHM(view.workedMs) : '');
    host.setToolTip(formatTrayTooltip(view));
  }

  miniWindowOptions(): Partial<BrowserWindowConstructorOptions> {
    // Everything macOS needs for the widget is a post-construction call — window
    // level and Spaces membership cannot be set through the constructor.
    return {};
  }

  configureMiniWindow(win: BrowserWindow): void {
    win.setAlwaysOnTop(true, 'floating');
    // Follow the user across Spaces and stay visible over fullscreen apps. The
    // process-type transform is skipped because `configureApp` already made this a
    // UIElement app; letting it run flashes the window on every call.
    win.setVisibleOnAllWorkspaces(true, {
      visibleOnFullScreen: true,
      skipTransformProcessType: true,
    });
  }

  panelWindowOptions(): Partial<BrowserWindowConstructorOptions> {
    // An NSPanel is the right shape for a menu-bar popover: it floats over
    // fullscreen apps and does not activate Dayly over the app the user is in.
    return { type: 'panel' };
  }

  async setLoginItemEnabled(enabled: boolean): Promise<void> {
    // Registration goes through SMAppService, so every write is a privileged change to
    // a system-owned database. Re-registering a login item that is already registered
    // buys nothing, which is what makes applying the preference on every startup free.
    if (app.getLoginItemSettings().openAtLogin === enabled) return;
    // Nothing here has to suppress the startup UI: `configureApp` makes Dayly an
    // accessory app and no window opens at launch, so a login launch is already silent.
    // `openAsHidden` would not help even if it were passed — it is deprecated and
    // ignored from macOS 13 on, where SMAppService owns the registration.
    //
    // A failed write rejects out of this method on purpose; the caller reports it
    // rather than leaving a preference the OS never stored looking saved.
    app.setLoginItemSettings({ openAtLogin: enabled });
  }

  async isLoginItemEnabled(): Promise<boolean> {
    // The same settings object also carries the SMAppService `status`, one of
    // `not-registered`, `enabled`, `requires-approval` or `not-found`. `openAtLogin` is
    // false for `requires-approval` — the state macOS leaves behind when the user turns
    // Dayly off in System Settings > General > Login Items — so reporting `openAtLogin`
    // verbatim reports what will actually happen at the next login, which is the answer
    // callers want.
    return app.getLoginItemSettings().openAtLogin;
  }

  /** Chromium reads the idle time from the OS directly here; no D-Bus in the way. */
  async readIdleMs(): Promise<number | null> {
    return powerMonitor.getSystemIdleTime() * MS_PER_SECOND;
  }

  /** Chromium reads idleness from the OS here; there is nothing to be refused by. */
  async probeIdleAvailable(): Promise<boolean> {
    return true;
  }

  async revealInFileManager(target: string): Promise<void> {
    shell.showItemInFolder(target);
  }

  private templateImage(): NativeImage {
    if (this.template === null) {
      const image = nativeImage.createFromPath(macTrayIconPath());
      // Template mode lets AppKit recolour the icon for the current menu bar,
      // including the inverted look while the menu is open.
      image.setTemplateImage(true);
      this.template = image;
    }
    return this.template;
  }
}

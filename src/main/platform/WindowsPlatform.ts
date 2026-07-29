import { app, nativeImage, shell, Tray } from 'electron';
import type { BrowserWindow, BrowserWindowConstructorOptions, NativeImage } from 'electron';
import type { OsKind, TimerState } from '@shared/types';
import type { Platform, TrayView } from './Platform';
import type { TrayHost, TrayHostCallbacks } from './TrayHost';
import { ElectronTrayHost } from './TrayHost';
import { formatTrayTooltip, trayIconStateFor, windowsTrayIconPath } from './trayIcons';
import type { TrayIconState } from './trayIcons';

/**
 * Windows: the notification area cannot show text, so the icon itself encodes the
 * state and the live numbers live in the tooltip. Users who want a glanceable total
 * get the mini-window, which is why it defaults on here.
 */
export class WindowsPlatform implements Platform {
  readonly os: OsKind = 'win32';
  readonly supportsTrayTitle = false;
  readonly miniWindowDefaultOn = true;
  /** Only the tooltip changes, and nobody watches a tooltip tick. */
  readonly trayRefreshIntervalMs = 30_000;

  /**
   * NSIS installs an unsigned package without complaint, so differential updates work
   * end to end. SmartScreen only ever appears on the *first* install, downloaded by
   * hand from the Releases page — it never sees an in-place update.
   *
   * An MSIX build is the exception, and `process.windowsStore` is Electron's own signal
   * for it. A packaged app cannot rewrite its own install: the package is immutable and
   * the Store owns servicing. Left true, the updater would find a GitHub release newer
   * than the Store's copy and offer an update that can never install — so the gate in
   * `UpdateService` shuts here instead, and nothing is ever downloaded.
   */
  readonly supportsAutoUpdate = !process.windowsStore;

  readonly releasesUrl = 'https://github.com/faizrazadec/dayly/releases';

  /** The notification area has no selected state to hold. */
  readonly supportsTrayHighlight = false;

  private readonly images = new Map<TrayIconState, NativeImage>();

  configureApp(): void {
    // Without an explicit AppUserModelID, Windows attributes toast notifications
    // and the taskbar grouping to `electron.app.Electron` instead of to Dayly.
    app.setAppUserModelId('me.faizraza.dayly');
  }

  async detectTrayAvailable(): Promise<boolean> {
    return true;
  }

  trayImagePath(state: TimerState): string {
    return windowsTrayIconPath(state);
  }

  createTrayHost(callbacks: TrayHostCallbacks): TrayHost | null {
    const tray = new Tray(this.stateImage('IDLE'));
    // Popup, not attached: an attached menu opens on left click too, which would put
    // the menu on top of the panel that same click just opened.
    return new ElectronTrayHost(tray, { mode: 'popup', supportsTitle: false, callbacks });
  }

  applyTray(host: TrayHost, view: TrayView): void {
    host.setImage(windowsTrayIconPath(view.state), false);
    host.setToolTip(formatTrayTooltip(view));
  }

  miniWindowOptions(): Partial<BrowserWindowConstructorOptions> {
    // `skipTaskbar` also gives the window the tool-window style, which keeps the
    // floating widget out of Alt+Tab.
    return { skipTaskbar: true };
  }

  configureMiniWindow(_win: BrowserWindow): void {
    // Nothing left to do: window levels and workspace visibility are macOS/Linux
    // concepts, and the constructor options cover the rest on Windows.
  }

  panelWindowOptions(): Partial<BrowserWindowConstructorOptions> {
    // The shared options (frameless, non-resizable, `skipTaskbar`) already describe
    // a Windows popup; there is no per-OS delta.
    return {};
  }

  async setLoginItemEnabled(enabled: boolean): Promise<void> {
    // Skip a redundant registry write when the state already matches, so applying the
    // preference on startup is free.
    if (app.getLoginItemSettings().openAtLogin === enabled) return;
    // Writes the Run registry key; `openAsHidden` is macOS-only, and Dayly starts
    // without a visible window anyway.
    app.setLoginItemSettings({ openAtLogin: enabled });
  }

  async isLoginItemEnabled(): Promise<boolean> {
    return app.getLoginItemSettings().openAtLogin;
  }

  async revealInFileManager(target: string): Promise<void> {
    shell.showItemInFolder(target);
  }

  /** Cached so a state change does not re-read the .ico from disk every refresh. */
  private stateImage(state: TimerState): NativeImage {
    const key = trayIconStateFor(state);
    const cached = this.images.get(key);
    if (cached !== undefined) return cached;

    const image = nativeImage.createFromPath(this.trayImagePath(state));
    this.images.set(key, image);
    return image;
  }
}

import { app, nativeImage, shell } from 'electron';
import type { BrowserWindow, BrowserWindowConstructorOptions, NativeImage, Tray } from 'electron';
import type { OsKind, TimerState } from '@shared/types';
import type { Platform, TrayView } from './Platform';
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
   */
  readonly supportsAutoUpdate = true;
  readonly releasesUrl = 'https://github.com/faizrazadec/dayly/releases';

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

  applyTray(tray: Tray, view: TrayView): void {
    tray.setImage(this.stateImage(view.state));
    tray.setToolTip(formatTrayTooltip(view));
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

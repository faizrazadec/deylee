/**
 * The platform abstraction.
 *
 * This directory is the **only** place in Dayly that is allowed to look at
 * `process.platform`: `createPlatform()` branches once at startup and every other
 * module talks to the `Platform` interface. That keeps macOS's menu-bar title,
 * Windows' state-encoding icons and Linux's XDG autostart out of the services, the
 * window manager and the tray controller, which are otherwise identical everywhere.
 */

import type { BrowserWindow, BrowserWindowConstructorOptions } from 'electron';
import type { OsKind, TimerState } from '@shared/types';
import type { TrayHost, TrayHostCallbacks } from './TrayHost';
import { LinuxPlatform } from './LinuxPlatform';
import { MacPlatform } from './MacPlatform';
import { WindowsPlatform } from './WindowsPlatform';

/** Everything the tray needs to draw itself, as of the current refresh tick. */
export interface TrayView {
  state: TimerState;
  workedMs: number;
  breakMs: number;
}

export interface Platform {
  readonly os: OsKind;
  /** Only macOS can render live text next to the tray icon. */
  readonly supportsTrayTitle: boolean;
  readonly miniWindowDefaultOn: boolean;
  /** How often the tray label/tooltip is refreshed. mac 1000ms, win/linux 30000ms. */
  readonly trayRefreshIntervalMs: number;

  /**
   * Whether a downloaded update can actually be *installed* on this platform.
   *
   * This is the second half of `UpdateService`'s gate (the first is `app.isPackaged`).
   * It lives here because the answer is a per-OS packaging fact — Squirrel.Mac's
   * signature requirement, NSIS, the AppImage/.deb split — and packaging facts are
   * exactly what this directory exists to keep out of the rest of the app.
   */
  readonly supportsAutoUpdate: boolean;

  /** Where a user is sent when Dayly cannot update itself. Same page everywhere. */
  readonly releasesUrl: string;

  /**
   * True when the menu-bar item can hold a selection highlight while the panel is
   * open. Only the macOS host can, and only when its native addon loaded.
   */
  readonly supportsTrayHighlight: boolean;

  /** dock.hide(), app user model id, GTK hints — called once, before windows exist. */
  configureApp(): void;

  /** Probes whether a tray host actually exists (always true on mac/windows). */
  detectTrayAvailable(): Promise<boolean>;

  /** Absolute path to the tray image for a state. */
  trayImagePath(state: TimerState): string;

  /**
   * Builds the menu-bar / tray surface, or returns null when one cannot be created.
   *
   * The implementation differs by more than styling: macOS owns an `NSStatusItem`
   * outright so the highlight can be held, while Windows and Linux use Electron's
   * `Tray`. `TrayController` is written against the returned interface and does not
   * know which it got.
   */
  createTrayHost(callbacks: TrayHostCallbacks): TrayHost | null;

  /** Applies image + title + tooltip for the current view. */
  applyTray(host: TrayHost, view: TrayView): void;

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

export function createPlatform(): Platform {
  switch (process.platform) {
    case 'darwin':
      return new MacPlatform();
    case 'win32':
      return new WindowsPlatform();
    default:
      // The remaining Electron targets (linux, freebsd, openbsd) all speak XDG:
      // autostart files, StatusNotifierItem trays, and no menu-bar title.
      return new LinuxPlatform();
  }
}

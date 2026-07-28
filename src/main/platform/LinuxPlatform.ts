import { app, nativeImage, shell } from 'electron';
import type { BrowserWindow, BrowserWindowConstructorOptions, NativeImage, Tray } from 'electron';
import { execFile } from 'node:child_process';
import { access, mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import type { OsKind, TimerState } from '@shared/types';
import type { Platform, TrayView } from './Platform';
import { formatTrayTooltip, linuxTrayIconPath, trayIconStateFor } from './trayIcons';
import type { TrayIconState } from './trayIcons';

/** The probe runs during startup, so a wedged session bus must not stall the app. */
const DBUS_PROBE_TIMEOUT_MS = 1_500;

/** Either name owned on the session bus means some panel hosts StatusNotifierItems. */
const WATCHER_NAMES = [
  'org.kde.StatusNotifierWatcher',
  'org.freedesktop.StatusNotifierWatcher',
] as const;

const AUTOSTART_FILE_NAME = 'dayly.desktop';

/**
 * Linux: the tray is the one thing that cannot be taken for granted — GNOME ships
 * without a StatusNotifierItem host unless an extension provides one — so the tray
 * is probed before it is created and the mini-window defaults on as a fallback.
 */
export class LinuxPlatform implements Platform {
  readonly os: OsKind = 'linux';
  readonly supportsTrayTitle = false;
  readonly miniWindowDefaultOn = true;
  /** Only the tooltip changes, and nobody watches a tooltip tick. */
  readonly trayRefreshIntervalMs = 30_000;

  /**
   * Only an AppImage can replace itself: it is a single file the user owns, which is
   * exactly what `$APPIMAGE` points at. A .deb lives under /usr, belongs to dpkg and
   * needs root to change, so there is no updater for it at all — that build links to
   * the Releases page instead. `$APPIMAGE` is the runtime's own signal and the same
   * variable the autostart entry above relies on.
   */
  readonly supportsAutoUpdate =
    typeof process.env.APPIMAGE === 'string' && process.env.APPIMAGE.length > 0;
  readonly releasesUrl = 'https://github.com/faizrazadec/dayly/releases';

  /**
   * StatusNotifierItem exposes a menu and little else — click events are swallowed by
   * the host shell and `popUpContextMenu` does nothing. So the menu stays attached, and
   * "Open Dayly" in it is how the panel is reached on Linux.
   */
  readonly trayMenuMode = 'attached' as const;

  private readonly images = new Map<TrayIconState, NativeImage>();

  configureApp(): void {
    // Deliberately empty. `setAppUserModelId` is Windows-only; GTK switches such as
    // `--gtk-version` have to be appended before `whenReady`, which has already
    // resolved by the time this runs; and `app.setName` must never be called here
    // because `app.getPath('userData')` is derived from it and the database has not
    // been opened yet. The autostart entry is named after the app name for the same
    // reason — that is how GNOME and Wayland match a window to its .desktop file.
  }

  async detectTrayAvailable(): Promise<boolean> {
    // No display server means no panel to host an indicator: a headless run, an ssh
    // session, or a service start before the session is up.
    if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) return false;

    const viaGdbus = await probe('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.DBus',
      '--object-path',
      '/org/freedesktop/DBus',
      '--method',
      'org.freedesktop.DBus.ListNames',
    ]);
    if (viaGdbus !== null) return hasStatusNotifierWatcher(viaGdbus);

    // gdbus comes with glib and is almost always present; dbus-send is the fallback
    // for stripped-down images. Both ask the bus the same question.
    const viaDbusSend = await probe('dbus-send', [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.DBus',
      '/org/freedesktop/DBus',
      'org.freedesktop.DBus.ListNames',
    ]);
    return viaDbusSend !== null && hasStatusNotifierWatcher(viaDbusSend);
  }

  trayImagePath(state: TimerState): string {
    return linuxTrayIconPath(state);
  }

  applyTray(tray: Tray, view: TrayView): void {
    tray.setImage(this.stateImage(view.state));
    tray.setToolTip(formatTrayTooltip(view));
  }

  miniWindowOptions(): Partial<BrowserWindowConstructorOptions> {
    // `_NET_WM_WINDOW_TYPE_UTILITY` is what X11 window managers honour for a small
    // floating widget: no taskbar entry, no pager entry, kept above its siblings.
    return { type: 'utility' };
  }

  configureMiniWindow(win: BrowserWindow): void {
    // Sticky across virtual desktops, matching the macOS behaviour. There is no
    // fullscreen option here — that field is macOS-only.
    win.setVisibleOnAllWorkspaces(true);
  }

  panelWindowOptions(): Partial<BrowserWindowConstructorOptions> {
    // Same reasoning as the mini-window: the panel is a transient popup that hides
    // on blur, so it has no business in the taskbar or the window switcher.
    return { type: 'utility' };
  }

  async setLoginItemEnabled(enabled: boolean): Promise<void> {
    // `app.setLoginItemSettings` is macOS/Windows only, so autostart is an XDG file.
    const file = autostartFilePath();
    if (!enabled) {
      // `force` swallows ENOENT, so disabling twice is not an error.
      await rm(file, { force: true });
      return;
    }
    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, desktopEntry(), { encoding: 'utf8', mode: 0o644 });
  }

  async isLoginItemEnabled(): Promise<boolean> {
    try {
      await access(autostartFilePath());
      return true;
    } catch {
      return false;
    }
  }

  async revealInFileManager(target: string): Promise<void> {
    // `showItemInFolder` needs a file manager that implements the FileManager1 DBus
    // interface and silently does nothing on several desktops, so open the
    // containing directory instead — that always resolves to *something*.
    await shell.openPath(dirname(target));
  }

  /** Cached so a state change does not re-read the PNG from disk every refresh. */
  private stateImage(state: TimerState): NativeImage {
    const key = trayIconStateFor(state);
    const cached = this.images.get(key);
    if (cached !== undefined) return cached;

    const image = nativeImage.createFromPath(this.trayImagePath(state));
    this.images.set(key, image);
    return image;
  }
}

function hasStatusNotifierWatcher(busNames: string): boolean {
  return WATCHER_NAMES.some((name) => busNames.includes(name));
}

/**
 * Runs a probe command and resolves its stdout, or `null` for **any** failure —
 * missing binary, non-zero exit, unreachable bus, timeout or a crash. Tray detection
 * is best-effort by definition: it must never throw and never hang, because a false
 * answer only costs the user a mini-window they can turn off.
 */
function probe(command: string, args: readonly string[]): Promise<string | null> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (value: string | null): void => {
      if (settled) return;
      settled = true;
      resolve(value);
    };

    try {
      const child = execFile(
        command,
        args,
        {
          timeout: DBUS_PROBE_TIMEOUT_MS,
          killSignal: 'SIGKILL',
          maxBuffer: 1024 * 1024,
          windowsHide: true,
        },
        (error, stdout) => finish(error === null ? stdout : null),
      );
      // A missing binary surfaces as an 'error' event as well as in the callback;
      // `finish` is idempotent, so whichever arrives first wins.
      child.on('error', () => finish(null));
    } catch {
      finish(null);
    }
  });
}

function autostartFilePath(): string {
  // The XDG autostart directory; every mainstream desktop reads it at login.
  return join(app.getPath('home'), '.config', 'autostart', AUTOSTART_FILE_NAME);
}

/**
 * `$APPIMAGE` is preferred over the executable path because an AppImage runs from a
 * FUSE mount under /tmp that will not exist at the next login, while `$APPIMAGE`
 * points at the file the user actually keeps.
 */
function desktopEntry(): string {
  const exec = process.env.APPIMAGE ?? app.getPath('exe');
  return `${[
    '[Desktop Entry]',
    'Type=Application',
    'Name=Dayly',
    'Comment=Local-only time tracker',
    `Exec=${quoteExecPath(exec)} --hidden`,
    'Icon=dayly',
    'Terminal=false',
    'X-GNOME-Autostart-enabled=true',
  ].join('\n')}\n`;
}

/**
 * The desktop-entry spec parses `Exec` into words, so a path containing spaces has
 * to be quoted and the reserved characters inside the quotes escaped.
 */
function quoteExecPath(value: string): string {
  if (!/[\s"'`$\\><~|&;*?#()]/.test(value)) return value;
  return `"${value.replace(/(["`$\\])/g, '\\$1')}"`;
}

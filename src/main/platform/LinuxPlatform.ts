import { app, nativeImage, powerMonitor, shell, Tray } from 'electron';
import type { BrowserWindow, BrowserWindowConstructorOptions, NativeImage } from 'electron';
import { execFile } from 'node:child_process';
import { access, mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { MS_PER_SECOND } from '@shared/time';
import type { OsKind, TimerState } from '@shared/types';
import type { Platform, TrayView } from './Platform';
import type { TrayHost, TrayHostCallbacks } from './TrayHost';
import { ElectronTrayHost } from './TrayHost';
import { formatTrayTooltip, linuxTrayIconPath, trayIconStateFor } from './trayIcons';
import type { TrayIconState } from './trayIcons';

/** The probe runs during startup, so a wedged session bus must not stall the app. */
const DBUS_PROBE_TIMEOUT_MS = 1_500;

/** Either name owned on the session bus means some panel hosts StatusNotifierItems. */
const WATCHER_NAMES = [
  'org.kde.StatusNotifierWatcher',
  'org.freedesktop.StatusNotifierWatcher',
] as const;

/**
 * The .desktop basename this app installs outside a snap, matching
 * `linux.executableName` in electron-builder.yml.
 */
const DESKTOP_BASE_NAME = 'dayly-time-tracker';

/**
 * Must match `linux.executableName` in electron-builder.yml, because that is what the
 * snap declares in its `autostart:` entry — snapd only honours the file it was told to
 * look for, so a mismatch here writes an autostart entry nothing ever reads.
 */
const AUTOSTART_FILE_NAME = `${DESKTOP_BASE_NAME}.desktop`;

/**
 * What the entry was called before the executable was renamed to match the registered
 * snap name. Anyone who enabled "Launch at login" on an earlier .deb or AppImage still
 * has this file, and it would go on starting Dayly at login while the toggle read
 * "off" — so it is cleaned up alongside the current one rather than left orphaned.
 */
const LEGACY_AUTOSTART_FILE_NAME = 'dayly.desktop';

/**
 * Mutter's idle monitor. `GetIdletime` on this object is the one member snapd's
 * `desktop` interface permits — `AddIdleWatch`, which Chromium reaches for first, is
 * refused.
 */
const MUTTER_IDLE_NAME = 'org.gnome.Mutter.IdleMonitor';
const MUTTER_IDLE_PATH = '/org/gnome/Mutter/IdleMonitor/Core';

/** Reply shape: `(uint64 2672423,)`. */
function parseGdbusUint64(reply: string): number | null {
  const match = /\(uint64\s+(\d+),?\)/.exec(reply);
  if (match === null) return null;
  const value = Number(match[1]);
  return Number.isFinite(value) ? value : null;
}

/**
 * True when an environment variable is both present and non-empty.
 *
 * The packaging runtimes all announce themselves this way — `$APPIMAGE`, `$SNAP`,
 * `$FLATPAK_ID` — and an empty string is not an announcement.
 */
function envSet(name: string): boolean {
  const value = process.env[name];
  return typeof value === 'string' && value.length > 0;
}

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
   * Electron implements `lock-screen` / `unlock-screen` for macOS and Windows only.
   * On Linux they never arrive, whatever the desktop or the packaging, so a
   * pause-on-lock toggle here would be wired to nothing.
   */
  readonly supportsLockDetection = false;

  /**
   * Only an AppImage can replace itself: it is a single file the user owns, which is
   * exactly what `$APPIMAGE` points at. A .deb lives under /usr, belongs to dpkg and
   * needs root to change, so there is no updater for it at all — that build links to
   * the Releases page instead. `$APPIMAGE` is the runtime's own signal and the same
   * variable the autostart entry above relies on.
   */
  readonly supportsAutoUpdate = envSet('APPIMAGE');

  /**
   * Linux has three shut-gate cases and only one of them is a shortcoming.
   *
   * A snap or a Flatpak is updated by its store, on its own schedule, and both are
   * read-only at runtime — telling those users to visit the Releases page would send
   * them away from the copy that actually gets fixed. A .deb genuinely has no updater
   * and the Releases page is the right answer. Null is the AppImage, which updates
   * itself. `$SNAP` and `$FLATPAK_ID` are the runtimes' own signals.
   */
  readonly autoUpdateBlockedReason = envSet('SNAP')
    ? 'The Snap Store keeps Dayly up to date.'
    : envSet('FLATPAK_ID')
      ? 'Flatpak keeps Dayly up to date.'
      : this.supportsAutoUpdate
        ? null
        : 'This build cannot update itself — check the Releases page.';

  readonly releasesUrl = 'https://github.com/faizrazadec/dayly/releases';

  /** No Linux shell highlights an indicator, and none exposes a way to ask. */
  readonly supportsTrayHighlight = false;

  private readonly images = new Map<TrayIconState, NativeImage>();

  configureApp(): void {
    // `setAppUserModelId` is Windows-only; GTK switches such as `--gtk-version` have
    // to be appended before `whenReady`, which has already resolved by the time this
    // runs; and `app.setName` must never be called here because
    // `app.getPath('userData')` is derived from it and the database has not been
    // opened yet.
    //
    // The two things that *do* belong here both have to land before anything else
    // reads them: the application id before the first window exists, and the userData
    // root before the store and the database are opened. Bootstrap calls this first.
    this.claimSnapApplicationId();
    this.redirectSnapUserData();
  }

  /**
   * Reports the application id snapd's desktop entry actually carries.
   *
   * snapd re-exports the entry as `<instance>_<app>.desktop`, and on Wayland that
   * basename *is* the id the shell matches windows against. Reporting the unprefixed
   * name leaves every window unassociated, so GNOME concludes the app is not running:
   * a launcher click then starts another process rather than raising the window, and
   * that process loses the race against focus-stealing prevention and appears to do
   * nothing at all. `StartupWMClass` cannot rescue it — that is read only under X11,
   * and Dayly runs as a native Wayland client.
   *
   * Done here rather than through `desktopName` in package.json because the right
   * answer differs by packaging: the .deb and the AppImage install plain
   * `dayly-time-tracker.desktop`, which is what package.json already declares, and only
   * the snap carries the prefix.
   */
  private claimSnapApplicationId(): void {
    const instance = process.env.SNAP_INSTANCE_NAME ?? process.env.SNAP_NAME;
    if (instance === undefined || instance.length === 0) return;
    app.setDesktopName(`${instance}_${DESKTOP_BASE_NAME}.desktop`);
  }

  /**
   * Moves userData off the per-revision directory when running as a snap.
   *
   * Electron resolves it under `$SNAP_USER_DATA`, which snapd keeps per revision and
   * rolls back with `snap revert` — a user recovering from a bad update would silently
   * lose every tracked hour. `$SNAP_USER_COMMON` is the revision-independent directory
   * snapd provides for exactly this, and moving the root moves the database, the
   * preferences and the backups together rather than leaving them in three places.
   */
  private redirectSnapUserData(): void {
    const common = process.env.SNAP_USER_COMMON;
    if (common === undefined || common.length === 0) return;
    app.setPath('userData', join(common, 'dayly'));
  }

  async detectTrayAvailable(): Promise<boolean> {
    // No display server means no panel to host an indicator: a headless run, an ssh
    // session, or a service start before the session is up.
    if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) return false;

    // Ruled out before the bus is asked, because the bus gives the wrong answer here:
    // the watcher is present and reachable, so every probe below says yes, and the icon
    // still never appears.
    if (trayBlockedByConfinement()) {
      console.warn('[dayly] this snap cannot show a tray icon; using the mini window');
      return false;
    }

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
    if (viaDbusSend !== null) return hasStatusNotifierWatcher(viaDbusSend);

    // Neither probe could run at all — the ordinary case inside a snap, where neither
    // binary is part of the confined runtime. That is *unknown*, not "no tray", and
    // the two wrong answers are not equally cheap. Answering "no" hides the tray
    // permanently on a desktop that has a perfectly good StatusNotifierItem host, and
    // nothing ever re-checks. Answering "yes" costs nothing when it is wrong, because
    // `createTrayHost` already catches a tray that refuses to be created and reports
    // null, which lands on the same fallback. So assume it is there.
    return true;
  }

  trayImagePath(state: TimerState): string {
    return linuxTrayIconPath(state);
  }

  createTrayHost(callbacks: TrayHostCallbacks): TrayHost | null {
    let tray: Tray;
    try {
      tray = new Tray(this.stateImage('IDLE'));
    } catch (error: unknown) {
      // A desktop can advertise a StatusNotifierItem host and still refuse the icon.
      // Reporting null puts it down the same path as "no tray at all".
      console.error('[dayly] the tray icon could not be created', error);
      return null;
    }
    // Attached: StatusNotifierItem swallows click events and `popUpContextMenu` is a
    // no-op, so the menu is the whole interaction on Linux.
    return new ElectronTrayHost(tray, { mode: 'attached', supportsTitle: false, callbacks });
  }

  applyTray(host: TrayHost, view: TrayView): void {
    host.setImage(linuxTrayIconPath(view.state), false);
    host.setToolTip(formatTrayTooltip(view));
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
    // Removed on both paths, not only when disabling: leaving it behind while writing
    // the current entry would start Dayly twice at login.
    // `force` swallows ENOENT, so a machine that never had the old name is not an error.
    await rm(autostartFilePath(LEGACY_AUTOSTART_FILE_NAME), { force: true });
    if (!enabled) {
      await rm(file, { force: true });
      return;
    }
    await mkdir(dirname(file), { recursive: true });
    await writeFile(file, desktopEntry(), { encoding: 'utf8', mode: 0o644 });
  }

  async isLoginItemEnabled(): Promise<boolean> {
    // The legacy name counts as enabled: an upgraded install still has that file and
    // it still launches Dayly, so reporting "off" would show a toggle contradicting
    // what the session actually does. Writing the preference again migrates it.
    for (const name of [AUTOSTART_FILE_NAME, LEGACY_AUTOSTART_FILE_NAME]) {
      try {
        await access(autostartFilePath(name));
        return true;
      } catch {
        // Try the next candidate.
      }
    }
    return false;
  }

  /**
   * Asked once, at startup, because the answer cannot be read off a single sample:
   * a Chromium that has given up answers 0, and so does a user at the keyboard.
   *
   * Mutter answering is proof enough. Where it does not, Chromium's own reading is
   * trustworthy — KWin and X11 reach it through channels AppArmor does not mediate —
   * with one exception: a confined app on GNOME, which is precisely where Chromium
   * asked for an idle watch, was refused, and latched.
   */
  async probeIdleAvailable(): Promise<boolean> {
    const fromMutter = await this.readMutterIdleMs();
    if (fromMutter !== null) return true;

    const desktop = process.env.XDG_CURRENT_DESKTOP ?? '';
    return !(envSet('SNAP') && /gnome/i.test(desktop));
  }

  async revealInFileManager(target: string): Promise<void> {
    // `showItemInFolder` needs a file manager that implements the FileManager1 DBus
    // interface and silently does nothing on several desktops, so open the
    // containing directory instead — that always resolves to *something*.
    await shell.openPath(dirname(target));
  }

  /**
   * Mutter first, Chromium second.
   *
   * Chromium's own answer is worthless under confinement and worse than useless: it
   * opens with `AddIdleWatch`, which no snap interface grants, and on refusal latches
   * `kNotAvailable` permanently and returns 0 from then on. Zero reads as "the user is
   * right here", so idle detection stops firing without a single error.
   *
   * `GetIdletime` on the same object *is* granted — by the `desktop` interface, which
   * auto-connects — so asking Mutter directly gets a true answer where Chromium cannot.
   * Verified inside this app's own confinement, where `GetIdletime` returns a real
   * figure and `AddIdleWatch` is refused by AppArmor in the same session.
   *
   * gdbus rather than a D-Bus client library: the tray probe already shells out this
   * way, it ships inside the snap, and the alternative was a dependency whose current
   * API was three days old. Once per poll, and the poll is every fifteen seconds.
   */
  async readIdleMs(): Promise<number | null> {
    const fromMutter = await this.readMutterIdleMs();
    if (fromMutter !== null) return fromMutter;

    // Not GNOME, or gdbus is absent. KWin and X11 answer Chromium through channels
    // that are not D-Bus mediated, so its number is trustworthy there.
    const chromium = powerMonitor.getSystemIdleTime() * MS_PER_SECOND;
    // A session that only ever answers 0 is the latched case above, not a user glued
    // to the keyboard — but they are indistinguishable from one sample, so this stays
    // honest and reports it. `probeIdleAvailable` is what tells them the difference.
    return chromium;
  }

  /** `GetIdletime` from Mutter, or null when it cannot answer. */
  private async readMutterIdleMs(): Promise<number | null> {
    const reply = await probe('gdbus', [
      'call',
      '--session',
      '--dest',
      MUTTER_IDLE_NAME,
      '--object-path',
      MUTTER_IDLE_PATH,
      '--method',
      `${MUTTER_IDLE_NAME}.GetIdletime`,
    ]);
    return reply === null ? null : parseGdbusUint64(reply);
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
 * The first Chromium whose tray a strict snap cannot show.
 *
 * Chromium 150 moved the indicator's D-Bus object paths to `/org/chromium/…`, and
 * snapd's AppArmor templates still name only the old `/StatusNotifierItem` and
 * `/com/canonical/dbusmenu`. Registration is therefore denied, but asynchronously and
 * on the far side of the bus: `new Tray()` returns an object quite happily, throws
 * nothing, and the icon simply never appears. Tracked as snapd LP#2161950.
 */
const SNAP_TRAY_BROKEN_FROM_CHROME = 150;

/**
 * True where the tray is known to be unshowable, so the mini-window fallback can take
 * over instead of the app running with no visible surface at all.
 *
 * This is a deliberate exception to "probe, don't assume": every probe reports a
 * healthy tray here, because the watcher genuinely is present and reachable. The part
 * that fails is invisible to us. Version-gated rather than blanket so it lapses on its
 * own once snapd widens the templates or Chromium moves again, and escapable with
 * DAYLY_FORCE_TRAY=1 for re-testing without a rebuild.
 */
function trayBlockedByConfinement(): boolean {
  if (!envSet('SNAP')) return false;
  if (envSet('DAYLY_FORCE_TRAY')) return false;
  const major = Number.parseInt(process.versions.chrome.split('.')[0] ?? '', 10);
  return !Number.isNaN(major) && major >= SNAP_TRAY_BROKEN_FROM_CHROME;
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

function autostartFilePath(name: string = AUTOSTART_FILE_NAME): string {
  // The XDG autostart directory; every mainstream desktop reads it at login.
  return join(app.getPath('home'), '.config', 'autostart', name);
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

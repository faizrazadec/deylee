/**
 * The update check — the one and only thing Dayly sends over the network.
 *
 * Three rules shape this file:
 *
 * 1. **Nothing happens without consent.** `autoDownload` is off, so a found update is
 *    reported and then waits. `autoInstallOnAppQuit` starts off and is armed only when
 *    the user asks for the download.
 * 2. **Nothing is ever forced.** Dayly is a tray app that stays open all day; a restart
 *    it did not ask for would throw away a running segment's context. An update installs
 *    when the user presses Install, or silently as part of a quit *they* chose.
 * 3. **Nothing pretends.** Where a self-update cannot work — dev, macOS, .deb — the
 *    status says so and the UI offers the Releases page. `electron-updater` is the only
 *    thing here that is allowed to make a request; this file never fetches anything
 *    itself, so switching the preference off really does make Dayly offline again.
 *
 * Failure is a normal outcome. GitHub being unreachable on a train is not an incident,
 * so every error is caught, flattened to one readable line and published as a status —
 * it never escapes into the main process.
 */

import { app, shell } from 'electron';
import { autoUpdater } from 'electron-updater';
// Aliased: `UpdateInfo` is also the name of Dayly's own renderer-facing shape, and the
// feed's version of it is a different, much larger object that never crosses the bridge.
import type { ProgressInfo, UpdateDownloadedEvent, UpdateInfo as FeedInfo } from 'electron-updater';

import type { UpdateInfo, UpdateStatus } from '@shared/types';
import type { Platform } from '@main/platform/Platform';
import type { PreferencesStore } from '@main/store/preferences';

/**
 * The first check waits for launch to settle. Window creation, the tray probe and the
 * recovery prompt all matter more in the first seconds than a version comparison does.
 */
export const FIRST_CHECK_DELAY_MS = 10_000;

/** Often enough to notice a release within a working day, rare enough to be invisible. */
export const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1_000;

const DEV_REASON = 'Updates are only checked in an installed build.';

/**
 * The last-resort wording, used only when a platform reports a shut gate without
 * saying why. Every platform does say why, so this should be unreachable.
 */
const UNSIGNED_REASON = 'Automatic updates need a signed build — check the Releases page.';

const NO_FEED_REASON = 'This build has no update feed — check the Releases page.';

/** Transport failures are the common case and deserve plain language, not an errno. */
const NETWORK_ERROR = /ENOTFOUND|EAI_AGAIN|ENETUNREACH|ENETDOWN|ECONNRESET|ECONNREFUSED|ETIMEDOUT|net::/i;

const MAX_MESSAGE_LENGTH = 200;

export interface UpdateServiceDeps {
  platform: Platform;
  prefs: PreferencesStore;
  onStatus: (status: UpdateStatus) => void;
}

/**
 * Flattens anything thrown into one line a person can read.
 *
 * `electron-updater` folds whole stacks and raw HTTP dumps into `Error.message`, and a
 * stack trace is not an answer to "what happened?".
 */
function readableError(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const first = raw.split('\n')[0].trim();
  if (first.length === 0) return 'The update check failed.';
  if (NETWORK_ERROR.test(first)) return 'Could not reach GitHub. Dayly will try again later.';
  return first.length > MAX_MESSAGE_LENGTH ? `${first.slice(0, MAX_MESSAGE_LENGTH - 1)}…` : first;
}

/** Progress arrives as a float and occasionally overshoots on the final chunk. */
function toPercent(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(100, Math.max(0, Math.round(value)));
}

export class UpdateService {
  private readonly platform: Platform;
  private readonly prefs: PreferencesStore;
  private readonly emit: (status: UpdateStatus) => void;

  private status: UpdateStatus = { kind: 'idle' };
  private timer: ReturnType<typeof setTimeout> | null = null;
  private unsubscribePrefs: (() => void) | null = null;

  private running = false;
  private listening = false;
  private pendingInstall = false;

  /** The version the feed most recently offered; the download needs a name to report. */
  private offeredVersion: string | null = null;

  /** One check at a time: the 6h tick and a user pressing Check must not race. */
  private inFlight: Promise<UpdateStatus> | null = null;

  constructor(deps: UpdateServiceDeps) {
    this.platform = deps.platform;
    this.prefs = deps.prefs;
    this.emit = deps.onStatus;

    // Both moments are ours, so both are taken away from the library up front. Reading
    // the `autoUpdater` singleton constructs the per-OS updater but touches no network
    // and no disk — the update config is loaded lazily, on the first check.
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = false;
  }

  /* ---------------------------------------------------------------------- */
  /* Lifecycle                                                               */
  /* ---------------------------------------------------------------------- */

  start(): void {
    if (this.running) return;
    this.running = true;

    // Every preference write lands here, which is what lets the toggle take effect
    // without a restart: off cancels the pending tick, on arms a fresh one.
    this.unsubscribePrefs = this.prefs.onChange(() => {
      this.reschedule();
    });
    this.schedule(FIRST_CHECK_DELAY_MS);
  }

  stop(): void {
    this.running = false;
    this.clearTimer();
    if (this.unsubscribePrefs !== null) {
      this.unsubscribePrefs();
      this.unsubscribePrefs = null;
    }
    this.stopListening();
  }

  getInfo(): UpdateInfo {
    return {
      currentVersion: app.getVersion(),
      canAutoUpdate: this.canAutoUpdate(),
      releasesUrl: this.platform.releasesUrl,
    };
  }

  getStatus(): UpdateStatus {
    return this.status;
  }

  /** True once an update is staged, so before-quit can install instead of just exiting. */
  hasPendingInstall(): boolean {
    return this.pendingInstall;
  }

  /* ---------------------------------------------------------------------- */
  /* The gate                                                                */
  /* ---------------------------------------------------------------------- */

  /**
   * Both halves have to hold: an unpackaged build has no feed to compare against, and a
   * platform that cannot install what it downloads must not download anything.
   */
  private canAutoUpdate(): boolean {
    return app.isPackaged && this.platform.supportsAutoUpdate;
  }

  /**
   * Why the gate is shut, in words meant for the Settings pane.
   *
   * Only the unpackaged case is decided here; everything else is a packaging fact and
   * belongs to the platform, which knows whether this build is a Store copy that
   * updates itself, a .deb that never will, or an unsigned build.
   */
  private gateReason(): string {
    if (!app.isPackaged) return DEV_REASON;
    return this.platform.autoUpdateBlockedReason ?? UNSIGNED_REASON;
  }

  /* ---------------------------------------------------------------------- */
  /* Commands                                                                */
  /* ---------------------------------------------------------------------- */

  /**
   * A user-initiated check. Runs even when the polling preference is off — pressing the
   * button *is* consent for this one request.
   *
   * Behind a shut gate this touches `autoUpdater` not at all: there is no feed Dayly
   * could ask about a macOS or .deb build, so inventing a fetch of its own to guess a
   * version would be both a lie about the release and a network call the user did not
   * agree to. The status says the truth and the UI offers the Releases link.
   */
  async checkNow(): Promise<UpdateStatus> {
    if (!this.canAutoUpdate()) {
      return this.publish({ kind: 'unsupported', reason: this.gateReason() });
    }
    return this.check();
  }

  /** The consent step. Downloads are never automatic. */
  async download(): Promise<UpdateStatus> {
    if (!this.canAutoUpdate()) {
      return this.publish({ kind: 'unsupported', reason: this.gateReason() });
    }
    // Already staged, or already running: pressing twice must not start a second one.
    if (this.status.kind === 'downloaded' || this.status.kind === 'downloading') {
      return this.status;
    }

    const version = this.offeredVersion;
    if (version === null) {
      return this.publish({
        kind: 'error',
        message: 'There is nothing to download yet — check for updates first.',
      });
    }

    this.startListening();
    this.publish({ kind: 'downloading', version, percent: 0 });

    // Armed here rather than in the constructor, because *here* is where the user said
    // yes. electron-updater registers its quit handler the instant the download
    // finishes and only if this flag is already true, so it cannot be flipped later:
    // arming it at consent time is what makes `hasPendingInstall()` mean anything.
    autoUpdater.autoInstallOnAppQuit = true;

    try {
      await autoUpdater.downloadUpdate();
      // `update-downloaded` has already published the final state.
      return this.status;
    } catch (error) {
      autoUpdater.autoInstallOnAppQuit = false;
      return this.publish({ kind: 'error', message: readableError(error) });
    }
  }

  /** Quits and installs immediately. Only meaningful once an update is staged. */
  installNow(): void {
    if (!this.pendingInstall) return;
    try {
      autoUpdater.quitAndInstall(false, true);
    } catch (error) {
      this.publish({ kind: 'error', message: readableError(error) });
    }
  }

  async openReleases(): Promise<void> {
    try {
      await shell.openExternal(this.platform.releasesUrl);
    } catch (error) {
      console.error('[dayly] could not open the Releases page:', error);
    }
  }

  /* ---------------------------------------------------------------------- */
  /* Polling                                                                 */
  /* ---------------------------------------------------------------------- */

  /**
   * A chained `setTimeout` rather than `setInterval`, so the preference is re-read on
   * every tick: turning the check off stops the polling at the next boundary instead of
   * leaving a live interval running against a disabled feature.
   */
  private schedule(delayMs: number): void {
    this.clearTimer();
    if (!this.running || !this.canAutoUpdate() || !this.pollingEnabled()) return;
    this.timer = setTimeout(() => {
      void this.tick();
    }, delayMs);
  }

  private async tick(): Promise<void> {
    this.timer = null;
    // Re-read: the preference may have been switched off while this tick was waiting.
    if (this.pollingEnabled()) await this.check();
    this.schedule(CHECK_INTERVAL_MS);
  }

  /** Called on every preference change; arms or cancels polling to match. */
  private reschedule(): void {
    if (!this.running) return;
    if (!this.canAutoUpdate() || !this.pollingEnabled()) {
      this.clearTimer();
      return;
    }
    // Already armed: an unrelated preference write must not push the next check back.
    if (this.timer !== null) return;
    this.schedule(FIRST_CHECK_DELAY_MS);
  }

  private pollingEnabled(): boolean {
    try {
      return this.prefs.get('updateCheckEnabled');
    } catch (error) {
      // An unreadable store is a reason to stay quiet, not to poll anyway.
      console.error('[dayly] could not read updateCheckEnabled:', error);
      return false;
    }
  }

  private clearTimer(): void {
    if (this.timer === null) return;
    clearTimeout(this.timer);
    this.timer = null;
  }

  /* ---------------------------------------------------------------------- */
  /* The check itself                                                        */
  /* ---------------------------------------------------------------------- */

  private check(): Promise<UpdateStatus> {
    const existing = this.inFlight;
    if (existing !== null) return existing;

    const run = this.performCheck().finally(() => {
      this.inFlight = null;
    });
    this.inFlight = run;
    return run;
  }

  private async performCheck(): Promise<UpdateStatus> {
    this.startListening();
    this.publish({ kind: 'checking' });

    try {
      const result = await autoUpdater.checkForUpdates();
      if (result === null) {
        // The updater declined: no `app-update.yml` shipped with this build.
        return this.publish({ kind: 'unsupported', reason: NO_FEED_REASON });
      }
      // `update-available` / `update-not-available` fire synchronously during the call
      // and have already published the real answer. The fallback covers a provider that
      // resolves without emitting either, so the UI never sticks on "Checking…".
      if (this.status.kind === 'checking') {
        if (!result.isUpdateAvailable) {
          this.offeredVersion = null;
          return this.publish({ kind: 'up-to-date', checkedAt: Date.now() });
        }
        this.offeredVersion = result.updateInfo.version;
        return this.publish({ kind: 'available', version: result.updateInfo.version });
      }
      return this.status;
    } catch (error) {
      return this.publish({ kind: 'error', message: readableError(error) });
    }
  }

  /* ---------------------------------------------------------------------- */
  /* electron-updater events                                                 */
  /* ---------------------------------------------------------------------- */

  private startListening(): void {
    if (this.listening) return;
    this.listening = true;
    autoUpdater.on('checking-for-update', this.handleChecking);
    autoUpdater.on('update-available', this.handleAvailable);
    autoUpdater.on('update-not-available', this.handleNotAvailable);
    autoUpdater.on('download-progress', this.handleProgress);
    autoUpdater.on('update-downloaded', this.handleDownloaded);
    autoUpdater.on('error', this.handleError);
  }

  private stopListening(): void {
    if (!this.listening) return;
    this.listening = false;
    autoUpdater.off('checking-for-update', this.handleChecking);
    autoUpdater.off('update-available', this.handleAvailable);
    autoUpdater.off('update-not-available', this.handleNotAvailable);
    autoUpdater.off('download-progress', this.handleProgress);
    autoUpdater.off('update-downloaded', this.handleDownloaded);
    autoUpdater.off('error', this.handleError);
  }

  // Bound fields rather than methods: `off` needs the same reference `on` was given.

  private readonly handleChecking = (): void => {
    this.publish({ kind: 'checking' });
  };

  private readonly handleAvailable = (info: FeedInfo): void => {
    this.offeredVersion = info.version;
    this.publish({ kind: 'available', version: info.version });
  };

  private readonly handleNotAvailable = (): void => {
    this.offeredVersion = null;
    this.publish({ kind: 'up-to-date', checkedAt: Date.now() });
  };

  private readonly handleProgress = (progress: ProgressInfo): void => {
    const version = this.offeredVersion;
    // Progress without a known version is a download nobody asked for through this
    // service; there is no honest label to put on it, so it is not reported.
    if (version === null) return;
    this.publish({ kind: 'downloading', version, percent: toPercent(progress.percent) });
  };

  private readonly handleDownloaded = (event: UpdateDownloadedEvent): void => {
    this.offeredVersion = event.version;
    this.pendingInstall = true;
    this.publish({ kind: 'downloaded', version: event.version });
  };

  private readonly handleError = (error: Error): void => {
    // Swallowed on purpose. An unreachable GitHub is an ordinary Tuesday, and an
    // unhandled 'error' on an EventEmitter would take the whole main process down.
    this.publish({ kind: 'error', message: readableError(error) });
  };

  /* ---------------------------------------------------------------------- */
  /* Status                                                                  */
  /* ---------------------------------------------------------------------- */

  /** Records the status and pushes it out. Returns it, so callers can `return this.publish(…)`. */
  private publish(status: UpdateStatus): UpdateStatus {
    this.status = status;
    try {
      this.emit(status);
    } catch (error) {
      // A dead window must not break the state machine that was telling it something.
      console.error('[dayly] update status listener failed:', error);
    }
    return status;
  }
}

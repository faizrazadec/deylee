/**
 * The tray icon: the app's primary surface.
 *
 * Two independent things happen here. The *menu* is structural — it only changes when
 * the timer state changes, and rebuilding it more often would close it under the user's
 * cursor. The *label* is live — re-applied on a platform-chosen interval (every second
 * on macOS, where the time is rendered next to the icon; every 30s elsewhere, where
 * only a tooltip shows it) and immediately on every snapshot, so a state change is
 * never a tick late.
 *
 * Which implementation actually draws the icon is `Platform`'s business: macOS owns an
 * NSStatusItem so the selection highlight can be held while the panel is open, and the
 * other two use Electron's Tray. Everything below is written against `TrayHost`.
 *
 * A tray is not guaranteed to exist: some Linux desktops ship no StatusNotifierItem
 * host. `init()` reports that as `false` rather than throwing, and the caller falls
 * back to the mini-window.
 */

import { liveTotals } from '@domain/duration';
import type { TimerSnapshot, TimerState, WindowKind } from '@shared/types';
import type { Platform } from '@main/platform/Platform';
import type { TrayHost, TrayMenuEntry } from '@main/platform/TrayHost';
import { TRAY_COMMAND } from '@main/platform/TrayHost';
import type { PreferencesStore } from '@main/store/preferences';
import type { TimerService } from '@main/services/TimerService';

function primaryLabel(state: TimerState): string {
  switch (state) {
    case 'RUNNING':
      return 'Pause';
    case 'PAUSED':
      return 'Resume';
    case 'IDLE':
    case 'ENDED':
      return 'Start';
  }
}

export class TrayController {
  private readonly platform: Platform;
  private readonly timer: TimerService;
  private readonly onTogglePanel: (bounds: Electron.Rectangle | null) => void;
  private readonly onOpen: (kind: WindowKind) => void;
  private readonly onQuit: () => void;

  private host: TrayHost | null = null;
  /** The state the current menu was built for; `null` until the first build. */
  private menuState: TimerState | null = null;
  private refreshTimer: ReturnType<typeof setInterval> | null = null;
  private unsubscribe: (() => void) | null = null;
  private panelOpen = false;

  constructor(deps: {
    platform: Platform;
    timer: TimerService;
    prefs: PreferencesStore;
    onTogglePanel: (bounds: Electron.Rectangle | null) => void;
    onOpen: (kind: WindowKind) => void;
    onQuit: () => void;
  }) {
    this.platform = deps.platform;
    this.timer = deps.timer;
    this.onTogglePanel = deps.onTogglePanel;
    this.onOpen = deps.onOpen;
    this.onQuit = deps.onQuit;
  }

  async init(): Promise<boolean> {
    if (this.host !== null) return true;
    if (!(await this.platform.detectTrayAvailable())) return false;

    const host = this.platform.createTrayHost({
      onLeftClick: () => {
        this.onTogglePanel(this.host?.getBounds() ?? null);
      },
      onRightClick: () => {
        // Only reached where the host does not handle the menu itself.
      },
      onCommand: (id) => {
        this.runCommand(id);
      },
    });
    if (host === null) return false;
    this.host = host;

    const snapshot = this.timer.getSnapshot();
    this.rebuildMenu(snapshot.state);
    this.apply(snapshot);

    this.unsubscribe = this.timer.onSnapshot((next) => {
      this.handleSnapshot(next);
    });
    this.refreshTimer = setInterval(() => {
      this.refresh();
    }, this.platform.trayRefreshIntervalMs);

    return true;
  }

  refresh(): void {
    if (this.host === null) return;
    this.apply(this.timer.getSnapshot());
  }

  /**
   * Holds the menu-bar selection highlight for as long as the panel is on screen —
   * the behaviour every other macOS menu-bar app has, and the reason the macOS host
   * owns its status item rather than using Electron's Tray. A no-op everywhere else.
   */
  setPanelOpen(open: boolean): void {
    if (this.panelOpen === open) return;
    this.panelOpen = open;
    this.host?.setHighlighted(open);
  }

  destroy(): void {
    if (this.refreshTimer !== null) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = null;
    }
    if (this.unsubscribe !== null) {
      this.unsubscribe();
      this.unsubscribe = null;
    }
    this.host?.destroy();
    this.host = null;
    this.menuState = null;
  }

  /* ------------------------------------------------------------------------ */
  /* Internals                                                                 */
  /* ------------------------------------------------------------------------ */

  private handleSnapshot(snapshot: TimerSnapshot): void {
    if (snapshot.state !== this.menuState) this.rebuildMenu(snapshot.state);
    this.apply(snapshot);
  }

  /** Re-applies the icon, title and tooltip for the totals as of right now. */
  private apply(snapshot: TimerSnapshot): void {
    const host = this.host;
    if (host === null) return;
    const totals = liveTotals(snapshot, Date.now());
    this.platform.applyTray(host, {
      state: snapshot.state,
      workedMs: totals.workedMs,
      breakMs: totals.breakMs,
    });
  }

  private rebuildMenu(state: TimerState): void {
    const host = this.host;
    if (host === null) return;

    const isActive = state === 'RUNNING' || state === 'PAUSED';
    const entries: TrayMenuEntry[] = [
      { id: TRAY_COMMAND.primary, label: primaryLabel(state), enabled: true },
      { id: TRAY_COMMAND.endDay, label: 'End Day', enabled: isActive },
      { separator: true },
      { id: TRAY_COMMAND.openPanel, label: 'Open Dayly', enabled: true },
      { id: TRAY_COMMAND.openHistory, label: 'History', enabled: true },
      { id: TRAY_COMMAND.openSettings, label: 'Settings', enabled: true },
      { separator: true },
      { id: TRAY_COMMAND.quit, label: 'Quit', enabled: true },
    ];

    host.setMenu(entries);
    this.menuState = state;
  }

  private runCommand(id: number): void {
    switch (id) {
      case TRAY_COMMAND.primary:
        this.runPrimaryAction();
        return;
      case TRAY_COMMAND.endDay:
        this.timer.endDay();
        return;
      case TRAY_COMMAND.openPanel:
        this.onOpen('panel');
        return;
      case TRAY_COMMAND.openHistory:
        this.onOpen('history');
        return;
      case TRAY_COMMAND.openSettings:
        this.onOpen('settings');
        return;
      case TRAY_COMMAND.quit:
        this.onQuit();
        return;
      default:
        return;
    }
  }

  /**
   * Resolved from the live state rather than the state the menu was built for, so a
   * click that races a transition still does the right thing.
   */
  private runPrimaryAction(): void {
    switch (this.timer.getSnapshot().state) {
      case 'IDLE':
      case 'ENDED':
        this.timer.start();
        return;
      case 'RUNNING':
        this.timer.pause();
        return;
      case 'PAUSED':
        this.timer.resume();
        return;
    }
  }
}

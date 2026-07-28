/**
 * The tray icon: the app's primary surface.
 *
 * Two independent things happen here. The *menu* is structural — it only changes
 * when the timer state changes, and rebuilding it more often would close it under
 * the user's cursor. The *label* is live — it is re-applied on a platform-chosen
 * interval (every second on macOS, where the time is rendered next to the icon;
 * every 30s elsewhere, where only a tooltip shows it) and immediately on every
 * snapshot, so a state change is never a tick late.
 *
 * A tray is not guaranteed to exist: some Linux desktops ship no StatusNotifierItem
 * host. `init()` reports that as `false` rather than throwing, and the caller falls
 * back to the mini-window.
 */

import { Menu, Tray } from 'electron';
import type { MenuItemConstructorOptions, Rectangle } from 'electron';
import { liveTotals } from '@domain/duration';
import type { TimerSnapshot, TimerState, WindowKind } from '@shared/types';
import type { Platform } from '@main/platform/Platform';
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
  private readonly onTogglePanel: (bounds: Rectangle | null) => void;
  private readonly onOpen: (kind: WindowKind) => void;
  private readonly onQuit: () => void;

  private tray: Tray | null = null;
  private menu: Menu | null = null;
  /** The state the current menu was built for; `null` until the first build. */
  private menuState: TimerState | null = null;
  private refreshTimer: ReturnType<typeof setInterval> | null = null;
  private unsubscribe: (() => void) | null = null;

  constructor(deps: {
    platform: Platform;
    timer: TimerService;
    prefs: PreferencesStore;
    onTogglePanel: (bounds: Rectangle | null) => void;
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
    if (this.tray !== null) return true;
    if (!(await this.platform.detectTrayAvailable())) return false;

    const snapshot = this.timer.getSnapshot();

    let tray: Tray;
    try {
      tray = new Tray(this.platform.trayImagePath(snapshot.state));
    } catch (error: unknown) {
      // A desktop can advertise a tray host and still refuse the icon. Treating
      // that exactly like "no tray" keeps the fallback in one place.
      console.error('[dayly] the tray icon could not be created', error);
      return false;
    }
    this.tray = tray;

    if (this.platform.trayMenuMode === 'popup') {
      // Left opens the panel, right opens the menu — and the two never collide,
      // because the menu is popped up explicitly rather than attached to the icon.
      tray.on('click', () => {
        this.onTogglePanel(tray.getBounds());
      });

      tray.on('right-click', () => {
        if (this.menu === null) return;
        tray.popUpContextMenu(this.menu);
      });
    }

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
    if (this.tray === null) return;
    this.apply(this.timer.getSnapshot());
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
    if (this.tray !== null) {
      if (!this.tray.isDestroyed()) this.tray.destroy();
      this.tray = null;
    }
    this.menu = null;
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
    const tray = this.tray;
    if (tray === null || tray.isDestroyed()) return;
    const totals = liveTotals(snapshot, Date.now());
    this.platform.applyTray(tray, {
      state: snapshot.state,
      workedMs: totals.workedMs,
      breakMs: totals.breakMs,
    });
  }

  private rebuildMenu(state: TimerState): void {
    const tray = this.tray;
    if (tray === null || tray.isDestroyed()) return;

    const isActive = state === 'RUNNING' || state === 'PAUSED';
    const template: MenuItemConstructorOptions[] = [
      {
        label: primaryLabel(state),
        click: () => {
          this.runPrimaryAction();
        },
      },
      {
        label: 'End Day',
        enabled: isActive,
        click: () => {
          this.timer.endDay();
        },
      },
      { type: 'separator' },
      {
        label: 'Open Dayly',
        click: () => {
          this.onOpen('panel');
        },
      },
      {
        label: 'History',
        click: () => {
          this.onOpen('history');
        },
      },
      {
        label: 'Settings',
        click: () => {
          this.onOpen('settings');
        },
      },
      { type: 'separator' },
      {
        label: 'Quit',
        click: () => {
          this.onQuit();
        },
      },
    ];

    this.menu = Menu.buildFromTemplate(template);
    this.menuState = state;

    // Only Linux attaches the menu. Attaching it on macOS or Windows would make a
    // LEFT click open the menu as well as firing 'click', so the menu would appear
    // on top of the panel that same click just opened.
    if (this.platform.trayMenuMode === 'attached') {
      tray.setContextMenu(this.menu);
    }
  }

  /**
   * Resolved from the live state rather than the state the menu was built for, so
   * a click that races a transition still does the right thing.
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

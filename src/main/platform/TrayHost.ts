/**
 * The menu-bar / tray surface, abstracted away from *which* implementation draws it.
 *
 * Windows and Linux use Electron's `Tray`. macOS uses an `NSStatusItem` this app owns
 * (see `MacStatusItemHost`), because Electron's Tray cannot hold the selection
 * highlight — `setHighlightMode` was removed in Electron 7 and never replaced.
 *
 * The menu is described as plain data rather than an Electron `Menu`, because there is
 * no public way to hand an Electron `Menu` to a natively-owned status item. Each host
 * turns the description into whatever its implementation needs.
 */

import { Menu, Tray } from 'electron';
import type { MenuItemConstructorOptions, Rectangle } from 'electron';

/** Stable ids for the tray menu, so a command survives the trip through native code. */
export const TRAY_COMMAND = {
  primary: 1,
  endDay: 2,
  openPanel: 3,
  openHistory: 4,
  openSettings: 5,
  quit: 6,
} as const;

export type TrayCommand = (typeof TRAY_COMMAND)[keyof typeof TRAY_COMMAND];

export type TrayMenuEntry =
  | { separator: true }
  | { separator?: false; id: TrayCommand; label: string; enabled: boolean };

export interface TrayHostCallbacks {
  onLeftClick(): void;
  onRightClick(): void;
  onCommand(id: number): void;
}

export interface TrayHost {
  setImage(path: string, template: boolean): void;
  /** macOS only; a no-op elsewhere, where the tray has no text. */
  setTitle(title: string): void;
  setToolTip(text: string): void;
  /**
   * Holds the menu-bar selection highlight while the panel is open. Only the macOS
   * host can do this; everywhere else it is a no-op, because neither shell highlights
   * a tray icon.
   */
  setHighlighted(on: boolean): void;
  /** Anchor for the panel, in screen coordinates. */
  getBounds(): Rectangle | null;
  setMenu(entries: readonly TrayMenuEntry[]): void;
  destroy(): void;
}

/**
 * How a host surfaces its menu.
 *
 * `attached` — bound to the icon with `setContextMenu`. Linux tray hosts
 * (StatusNotifierItem) support nothing else: click events do not fire reliably and
 * `popUpContextMenu` is a no-op, so the menu *is* the interaction.
 *
 * `popup` — held and shown explicitly on right-click, which is what Windows expects and
 * what keeps left-click free to open the panel.
 */
export type TrayMenuMode = 'attached' | 'popup';

/** Electron's own Tray. Used on Windows and Linux, and as the macOS fallback. */
export class ElectronTrayHost implements TrayHost {
  private tray: Tray | null;
  private menu: Menu | null = null;
  private readonly mode: TrayMenuMode;
  private readonly supportsTitle: boolean;
  private readonly callbacks: TrayHostCallbacks;

  constructor(tray: Tray, options: {
    mode: TrayMenuMode;
    supportsTitle: boolean;
    callbacks: TrayHostCallbacks;
  }) {
    this.tray = tray;
    this.mode = options.mode;
    this.supportsTitle = options.supportsTitle;
    this.callbacks = options.callbacks;

    if (this.mode === 'popup') {
      tray.on('click', () => {
        this.callbacks.onLeftClick();
      });
      tray.on('right-click', () => {
        if (this.menu === null) return;
        tray.popUpContextMenu(this.menu);
      });
    }
  }

  setImage(path: string): void {
    this.tray?.setImage(path);
  }

  setTitle(title: string): void {
    // `Tray.setTitle` exists only on macOS; calling it elsewhere would throw.
    if (!this.supportsTitle) return;
    this.tray?.setTitle(title);
  }

  setToolTip(text: string): void {
    this.tray?.setToolTip(text);
  }

  setHighlighted(): void {
    // Electron exposes no way to hold the highlight. See MacStatusItemHost.
  }

  getBounds(): Rectangle | null {
    return this.tray?.getBounds() ?? null;
  }

  setMenu(entries: readonly TrayMenuEntry[]): void {
    const template: MenuItemConstructorOptions[] = entries.map((entry) =>
      entry.separator === true
        ? { type: 'separator' }
        : {
            label: entry.label,
            enabled: entry.enabled,
            click: () => {
              this.callbacks.onCommand(entry.id);
            },
          },
    );
    this.menu = Menu.buildFromTemplate(template);
    // Only the attached mode binds it. Attaching on Windows would make a LEFT click
    // open the menu as well as firing 'click', putting the menu over the panel.
    if (this.mode === 'attached') this.tray?.setContextMenu(this.menu);
  }

  destroy(): void {
    if (this.tray !== null && !this.tray.isDestroyed()) this.tray.destroy();
    this.tray = null;
    this.menu = null;
  }
}

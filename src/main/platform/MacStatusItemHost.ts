/**
 * A macOS menu-bar item backed by an `NSStatusItem` this app owns, rather than by
 * Electron's `Tray`.
 *
 * The only reason this exists is the selection highlight. macOS highlights a status
 * item while its button is pressed, or for as long as it owns an open menu — holding it
 * for a custom panel needs `[NSStatusBarButton setHighlighted:]`. Electron exposed that
 * as `Tray.setHighlightMode` and removed it in v7, when the tray was rebuilt on
 * `[NSStatusItem button]` for macOS Catalina. Nothing replaced it, so without this the
 * icon flashes on click and then sits unhighlighted while the panel is open, which
 * reads as broken next to every other menu-bar app.
 *
 * Everything the addon does is public AppKit; it does not touch Electron's internals.
 * If the binary is missing — an unbuilt checkout, a machine without the Command Line
 * Tools — `load()` returns null and the caller falls back to `ElectronTrayHost`.
 */

import { createRequire } from 'node:module';
import type { Rectangle } from 'electron';
import type { TrayHost, TrayHostCallbacks, TrayMenuEntry } from './TrayHost';

interface StatusItemFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface StatusItemBinding {
  readonly supported: boolean;
  create(): boolean;
  destroy(): void;
  setImage(path: string, template: boolean): void;
  setTitle(title: string): void;
  setToolTip(text: string): void;
  setHighlighted(on: boolean): void;
  getFrame(): StatusItemFrame | null;
  setMenu(entries: readonly TrayMenuEntry[]): void;
  onClick(listener: (button: 'left' | 'right') => void): void;
  onCommand(listener: (id: number) => void): void;
}

interface AddonModule {
  available: boolean;
  binding: StatusItemBinding | null;
}

function isAddonModule(value: unknown): value is AddonModule {
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as { available?: unknown };
  return typeof candidate.available === 'boolean';
}

/**
 * `createRequire` rather than a static import: the addon is a CommonJS native module
 * that must not be bundled, and a bare `require` would be rewritten by the bundler.
 */
const requireAddon = createRequire(__filename);

let cached: StatusItemBinding | null | undefined;

function loadBinding(): StatusItemBinding | null {
  if (cached !== undefined) return cached;
  try {
    const loaded: unknown = requireAddon('@dayly/mac-status-item');
    cached = isAddonModule(loaded) && loaded.available ? loaded.binding : null;
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error('[dayly] native status item unavailable, using Electron Tray:', message);
    cached = null;
  }
  return cached;
}

export class MacStatusItemHost implements TrayHost {
  private binding: StatusItemBinding | null;

  private constructor(binding: StatusItemBinding, callbacks: TrayHostCallbacks) {
    this.binding = binding;
    binding.onClick((button) => {
      if (button === 'left') callbacks.onLeftClick();
      else callbacks.onRightClick();
    });
    binding.onCommand((id) => {
      callbacks.onCommand(id);
    });
  }

  /** Returns null when the addon is unavailable, so the caller can fall back. */
  static load(callbacks: TrayHostCallbacks): MacStatusItemHost | null {
    const binding = loadBinding();
    if (binding === null) return null;
    if (!binding.create()) return null;
    return new MacStatusItemHost(binding, callbacks);
  }

  setImage(path: string, template: boolean): void {
    this.binding?.setImage(path, template);
  }

  setTitle(title: string): void {
    this.binding?.setTitle(title);
  }

  setToolTip(text: string): void {
    this.binding?.setToolTip(text);
  }

  setHighlighted(on: boolean): void {
    this.binding?.setHighlighted(on);
  }

  getBounds(): Rectangle | null {
    const frame = this.binding?.getFrame() ?? null;
    if (frame === null) return null;
    // Before the menu bar has laid the item out, AppKit reports a placeholder rect.
    // Returning null lets the caller centre the panel instead of anchoring it to a
    // position that is about to change.
    if (!Number.isFinite(frame.x) || frame.width <= 0) return null;
    return frame;
  }

  setMenu(entries: readonly TrayMenuEntry[]): void {
    this.binding?.setMenu(entries);
  }

  destroy(): void {
    this.binding?.destroy();
    this.binding = null;
  }
}

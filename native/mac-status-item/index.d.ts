export interface StatusItemFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export type StatusItemMenuEntry =
  | { id: number; label: string; enabled: boolean; separator?: false }
  | { separator: true };

export interface StatusItemBinding {
  readonly supported: boolean;
  create(): boolean;
  destroy(): void;
  setImage(path: string, template: boolean): void;
  setTitle(title: string): void;
  setToolTip(text: string): void;
  /** Holds the menu-bar selection highlight — the capability Electron's Tray lost. */
  setHighlighted(on: boolean): void;
  /** Button bounds in Electron screen coordinates, or null before first layout. */
  getFrame(): StatusItemFrame | null;
  setMenu(entries: readonly StatusItemMenuEntry[]): void;
  onClick(listener: (button: 'left' | 'right') => void): void;
  onCommand(listener: (id: number) => void): void;
}

export declare const available: boolean;
export declare const binding: StatusItemBinding | null;

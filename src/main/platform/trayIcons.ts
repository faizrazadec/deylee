/**
 * What the tray shows: icon paths and the tooltip wording, shared by the three
 * platform implementations so the phrasing cannot drift between them.
 *
 * The artwork is produced by `scripts/generate-icons.mjs` and lives outside the
 * bundle, because Electron loads tray images from disk at runtime:
 *
 *   resources/tray/mac/trayTemplate.png (+ @2x)
 *   resources/tray/win/{idle,running,paused}.ico
 *   resources/tray/linux/{idle,running,paused}.png
 */

import { app } from 'electron';
import { join } from 'node:path';
import { formatHM } from '@shared/time';
import type { TimerState } from '@shared/types';
import type { TrayView } from './Platform';

/** The three states that have distinct artwork. */
export type TrayIconState = 'idle' | 'running' | 'paused';

/**
 * In development the icons are read straight out of the repo; in a packaged build
 * electron-builder copies `resources/` next to the asar, at `process.resourcesPath`.
 */
function resourcesRoot(): string {
  return app.isPackaged ? process.resourcesPath : join(app.getAppPath(), 'resources');
}

export function trayResourcePath(...segments: string[]): string {
  return join(resourcesRoot(), 'tray', ...segments);
}

/**
 * ENDED reuses the idle artwork: both mean "not counting right now", and a fourth
 * silhouette would be one more shape than a 16px icon can carry.
 */
export function trayIconStateFor(state: TimerState): TrayIconState {
  switch (state) {
    case 'RUNNING':
      return 'running';
    case 'PAUSED':
      return 'paused';
    case 'IDLE':
    case 'ENDED':
      return 'idle';
  }
}

/**
 * macOS gets one template image for every state — the live title beside it carries
 * the state instead. The `@2x` variant is picked up automatically by
 * `nativeImage.createFromPath`, so it is never referenced directly.
 */
export function macTrayIconPath(): string {
  return trayResourcePath('mac', 'trayTemplate.png');
}

export function windowsTrayIconPath(state: TimerState): string {
  return trayResourcePath('win', `${trayIconStateFor(state)}.ico`);
}

export function linuxTrayIconPath(state: TimerState): string {
  return trayResourcePath('linux', `${trayIconStateFor(state)}.png`);
}

/**
 * The tray tooltip. On Windows and Linux it is the only surface that can carry the
 * live numbers at all, so it spells out the state as well as both totals.
 */
export function formatTrayTooltip(view: TrayView): string {
  const totals = `${formatHM(view.workedMs)} worked · ${formatHM(view.breakMs)} break`;
  switch (view.state) {
    case 'RUNNING':
      return `Dayly — ${totals}`;
    case 'PAUSED':
      return `Dayly — paused · ${totals}`;
    case 'ENDED':
      return `Dayly — day ended · ${totals}`;
    case 'IDLE':
      return view.workedMs > 0 ? `Dayly — stopped · ${totals}` : 'Dayly — not tracking';
  }
}

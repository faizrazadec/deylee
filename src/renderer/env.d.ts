/// <reference types="vite/client" />

import type { DaylyApi } from '../shared/ipc';

declare global {
  interface Window {
    /** The only bridge between a renderer and the main process. */
    readonly dayly: DaylyApi;
  }
}

export {};

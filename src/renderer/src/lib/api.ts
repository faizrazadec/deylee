/**
 * The renderer's only doorway to the main process, plus the two helpers every
 * window entry needs.
 *
 * `window.dayly` is installed by the preload before any module here evaluates, so
 * capturing it once at module scope is safe and keeps call sites short.
 */

import { StrictMode, createElement } from 'react';
import type { ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import type { DaylyApi } from '@shared/ipc';

export const api: DaylyApi = window.dayly;

/** Mounts a window's root component. Every `<kind>/main.tsx` ends with this call. */
export function mountWindow(node: ReactNode): void {
  createRoot(document.getElementById('root')!).render(createElement(StrictMode, null, node));
}

/** Joins conditional class names. Falsy parts drop out, so `cond && 'x'` works. */
export function cn(...parts: Array<string | false | null | undefined>): string {
  let out = '';
  for (const part of parts) {
    if (typeof part !== 'string' || part.length === 0) continue;
    out = out.length === 0 ? part : `${out} ${part}`;
  }
  return out;
}

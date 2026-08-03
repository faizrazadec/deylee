/**
 * Theme application.
 *
 * `styles.css` declares the palette three times — light, `prefers-color-scheme:
 * dark` for the first paint, and `.dark` — so the class stamped here is what makes
 * an explicit preference beat the OS. Both classes are written, never just one:
 * without `.light` the media-query fallback would drag a user who chose light back
 * to dark on a dark desktop.
 */

import type { Preferences } from '@shared/types';

export type ThemePreference = Preferences['theme'];
export type ResolvedTheme = 'light' | 'dark';

const DARK_QUERY = '(prefers-color-scheme: dark)';

/** What `theme` means right now, resolving `'system'` against the OS. */
export function resolveTheme(theme: ThemePreference): ResolvedTheme {
  if (theme === 'system') return window.matchMedia(DARK_QUERY).matches ? 'dark' : 'light';
  return theme;
}

export function applyTheme(theme: ThemePreference): void {
  const resolved = resolveTheme(theme);
  const root = document.documentElement;
  root.classList.toggle('dark', resolved === 'dark');
  root.classList.toggle('light', resolved === 'light');
}

/**
 * Subscribe to OS appearance changes. Only worth wiring while the preference is
 * `'system'`; the returned function detaches the listener.
 */
export function watchSystemTheme(listener: (prefersDark: boolean) => void): () => void {
  const query = window.matchMedia(DARK_QUERY);
  const handler = (event: MediaQueryListEvent): void => listener(event.matches);
  query.addEventListener('change', handler);
  return () => query.removeEventListener('change', handler);
}

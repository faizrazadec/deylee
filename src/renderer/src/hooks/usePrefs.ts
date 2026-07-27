/**
 * Preferences, shared by every window.
 *
 * Writes go through the main process, which clamps and validates them, so the
 * object it returns — not the value that was requested — becomes local state.
 * Other windows learn about the same write through `onChanged`.
 */

import { useCallback, useEffect, useState } from 'react';
import type { Preferences } from '@shared/types';
import { api } from '@renderer/lib/api';
import { applyTheme, watchSystemTheme } from '@renderer/lib/theme';

export interface PrefsState {
  prefs: Preferences | null;
  setPref: <K extends keyof Preferences>(key: K, value: Preferences[K]) => Promise<void>;
}

export function usePrefs(): PrefsState {
  const [prefs, setPrefs] = useState<Preferences | null>(null);

  useEffect(() => {
    let active = true;

    const unsubscribe = api.prefs.onChanged((next) => {
      if (active) setPrefs(next);
    });

    void api.prefs
      .getAll()
      .then((all) => {
        // A change broadcast that beat the initial load is already newer.
        if (active) setPrefs((current) => current ?? all);
      })
      .catch(() => undefined);

    return () => {
      active = false;
      unsubscribe();
    };
  }, []);

  const setPref = useCallback(
    async <K extends keyof Preferences>(key: K, value: Preferences[K]): Promise<void> => {
      setPrefs(await api.prefs.set(key, value));
    },
    [],
  );

  const theme = prefs === null ? null : prefs.theme;
  useEffect(() => {
    if (theme === null) return undefined;
    applyTheme(theme);
    // Only `'system'` has to track the OS; an explicit choice is already applied.
    if (theme !== 'system') return undefined;
    return watchSystemTheme(() => applyTheme('system'));
  }, [theme]);

  return { prefs, setPref };
}

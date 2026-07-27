/**
 * Platform capabilities. Fixed for the life of the process — the tray probe and
 * the OS kind are resolved during startup — so this loads once and never refetches.
 */

import { useEffect, useState } from 'react';
import type { PlatformInfo } from '@shared/types';
import { api } from '@renderer/lib/api';

export function usePlatformInfo(): PlatformInfo | null {
  const [info, setInfo] = useState<PlatformInfo | null>(null);

  useEffect(() => {
    let active = true;

    void api.system
      .getPlatformInfo()
      .then((next) => {
        if (active) setInfo(next);
      })
      // Callers already handle `null` as "not known yet".
      .catch(() => undefined);

    return () => {
      active = false;
    };
  }, []);

  return info;
}

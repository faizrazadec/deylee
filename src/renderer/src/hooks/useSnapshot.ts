/**
 * The timer snapshot every window renders from, plus its live totals.
 *
 * The main process pushes a snapshot on every state change; between pushes the
 * displayed numbers come from `liveTotals(snapshot, tick)`, which is a pure
 * function of the stored timestamps.
 */

import { useEffect, useMemo, useState } from 'react';
import { liveTotals } from '@domain/duration';
import type { LiveTotals, TimerSnapshot } from '@shared/types';
import { api } from '@renderer/lib/api';
import { useTicker } from '@renderer/hooks/useTicker';

export interface SnapshotState {
  snapshot: TimerSnapshot | null;
  live: LiveTotals;
  tick: number;
}

/** Shown for the one frame before the first snapshot arrives. */
const EMPTY_TOTALS: LiveTotals = {
  workedMs: 0,
  breakMs: 0,
  targetProgress: 0,
  targetMs: 0,
  remainingToTargetMs: 0,
};

export function useSnapshot(): SnapshotState {
  const [snapshot, setSnapshot] = useState<TimerSnapshot | null>(null);
  const tick = useTicker(1000);

  useEffect(() => {
    let active = true;

    // Subscribe before seeding: a state change that happens while the seed is in
    // flight must not be lost, and the `?? seed` below keeps it from being undone.
    const unsubscribe = api.timer.onSnapshot((next) => {
      if (active) setSnapshot(next);
    });

    void api.timer
      .getSnapshot()
      .then((seed) => {
        if (active) setSnapshot((current) => current ?? seed);
      })
      // The window has no way to surface this; the next push will fill it in.
      .catch(() => undefined);

    return () => {
      active = false;
      unsubscribe();
    };
  }, []);

  const live = useMemo(
    () => (snapshot === null ? EMPTY_TOTALS : liveTotals(snapshot, tick)),
    [snapshot, tick],
  );

  return { snapshot, live, tick };
}

/**
 * The render clock. Every elapsed value in the app is recomputed from timestamps
 * against this tick — nothing increments a counter — so sleeps, clock changes and
 * midnight rollovers all land correctly on the next frame.
 */

import { useEffect, useState } from 'react';

export function useTicker(intervalMs = 1000): number {
  const [tick, setTick] = useState<number>(() => Date.now());

  useEffect(() => {
    // A non-positive period would spin the renderer; fall back to one second.
    const period = intervalMs > 0 ? intervalMs : 1000;

    const sync = (): void => setTick(Date.now());
    const syncIfVisible = (): void => {
      if (document.visibilityState === 'visible') sync();
    };

    const timer = window.setInterval(sync, period);
    // A hidden or backgrounded window is throttled to ~1/min, so it comes back
    // holding a stale value. Catch up the instant it is shown or focused rather
    // than letting the user watch the timer jump on the next interval.
    document.addEventListener('visibilitychange', syncIfVisible);
    window.addEventListener('focus', sync);

    return () => {
      window.clearInterval(timer);
      document.removeEventListener('visibilitychange', syncIfVisible);
      window.removeEventListener('focus', sync);
    };
  }, [intervalMs]);

  return tick;
}

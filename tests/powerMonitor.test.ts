/**
 * The sleep watchdog, and specifically its deduplication.
 *
 * The watchdog exists because `suspend` / `resume` are not guaranteed — never inside a
 * strict snap, and unreliably elsewhere. That makes double-counting the failure to
 * guard: on a machine that *does* report sleep, the same absence is visible twice, once
 * through the events and once through the clock jump, and reporting both would pause
 * the user's day twice over one nap.
 */

import { beforeEach, describe, expect, it, vi } from 'vitest';

/** `powerMonitor` is an EventEmitter; the service only ever adds and removes listeners. */
const listeners = new Map<string, () => void>();

vi.mock('electron', () => ({
  powerMonitor: {
    on: (event: string, handler: () => void) => listeners.set(event, handler),
    removeListener: (event: string) => listeners.delete(event),
  },
}));

const { PowerMonitorService, SLEEP_WATCHDOG_INTERVAL_MS, SLEEP_DRIFT_THRESHOLD_MS } =
  await import('@main/services/PowerMonitorService');

interface Gap {
  awayAt: number;
  backAt: number;
  reason: string;
}

function build(prefs: Record<string, boolean> = { autoPauseOnSleep: true }) {
  const gaps: Gap[] = [];
  const aways: number[] = [];
  const service = new PowerMonitorService({
    // Only `get` is reached; the rest of the store is irrelevant here.
    prefs: { get: (key: string) => prefs[key] ?? false } as never,
    onAway: (at) => aways.push(at),
    onBack: (awayAt, backAt, reason) => gaps.push({ awayAt, backAt, reason }),
  });
  return { service, gaps, aways };
}

/**
 * Simulate a sleep: the clock jumps forward, then the tick that was due *during* the
 * sleep finally runs.
 *
 * `advanceTimersByTime` moves the fake clock as well as firing timers, so the jump is
 * set short by exactly one interval — otherwise every assertion is off by 10s.
 */
function sleepThenTick(elapsedMs: number): void {
  vi.setSystemTime(Date.now() + elapsedMs - SLEEP_WATCHDOG_INTERVAL_MS);
  vi.advanceTimersByTime(SLEEP_WATCHDOG_INTERVAL_MS);
}

describe('PowerMonitorService sleep watchdog', () => {
  beforeEach(() => {
    listeners.clear();
    vi.useFakeTimers();
    vi.setSystemTime(0);
  });

  it('reports an absence the OS never announced', () => {
    const { service, gaps } = build();
    service.start();

    // The machine slept for an hour: the timer is due at +10s but the clock has moved
    // an hour by the time it runs.
    sleepThenTick(60 * 60 * 1_000);

    expect(gaps).toHaveLength(1);
    expect(gaps[0]?.reason).toBe('suspend');
    // The gap starts at the last moment the process was demonstrably awake, not at the
    // moment it noticed — otherwise the whole sleep counts as worked time.
    expect(gaps[0]?.awayAt).toBe(0);
    expect(gaps[0]?.backAt).toBe(60 * 60 * 1_000);
  });

  it('ignores a tick that merely ran late', () => {
    const { service, gaps } = build();
    service.start();

    // One millisecond under the threshold: a tick that ran late, not a sleep.
    sleepThenTick(SLEEP_WATCHDOG_INTERVAL_MS + SLEEP_DRIFT_THRESHOLD_MS - 1);

    expect(gaps).toHaveLength(0);
  });

  it('does not report an absence the OS already reported', () => {
    const { service, gaps } = build();
    service.start();

    // A real suspend/resume pair spanning an hour.
    listeners.get('suspend')?.();
    vi.setSystemTime(60 * 60 * 1_000);
    listeners.get('resume')?.();
    expect(gaps).toHaveLength(1);

    // The watchdog now runs and sees the same jump. It must stay quiet.
    vi.advanceTimersByTime(SLEEP_WATCHDOG_INTERVAL_MS);
    expect(gaps).toHaveLength(1);
  });

  it('leaves an open gap for the real resume to close', () => {
    const { service, gaps } = build();
    service.start();

    // Suspended, but not yet resumed, when the watchdog fires.
    listeners.get('suspend')?.();
    sleepThenTick(60 * 60 * 1_000);

    // The real event owns the gap: its instant is the accurate one.
    expect(gaps).toHaveLength(0);

    listeners.get('resume')?.();
    expect(gaps).toHaveLength(1);
    expect(gaps[0]?.awayAt).toBe(0);
  });

  it('respects the preference', () => {
    const { service, gaps } = build({ autoPauseOnSleep: false });
    service.start();

    sleepThenTick(60 * 60 * 1_000);

    expect(gaps).toHaveLength(0);
  });

  it('stops watching after stop()', () => {
    const { service, gaps } = build();
    service.start();
    service.stop();

    sleepThenTick(60 * 60 * 1_000);

    expect(gaps).toHaveLength(0);
  });
});

/**
 * The update lifecycle, as any window sees it.
 *
 * The main process owns the state machine: it broadcasts every transition, and the
 * request/response calls answer with the same status they broadcast. This hook is
 * therefore a mirror, not a source — it seeds once, then follows the broadcast.
 *
 * None of the four actions reject. An update is background work the user opted into,
 * so a failed call must never surface as an unhandled rejection in a window whose
 * real job is the timer.
 */

import { useCallback, useEffect, useState } from 'react';

import type { UpdateInfo, UpdateStatus } from '@shared/types';

import { api } from '@renderer/lib/api';

export interface UpdatesState {
  status: UpdateStatus;
  info: UpdateInfo | null;
  checkNow: () => Promise<void>;
  download: () => Promise<void>;
  installNow: () => Promise<void>;
  openReleases: () => Promise<void>;
}

/** Nothing has been asked yet — the same thing `idle` means in the main process. */
const INITIAL: UpdateStatus = { kind: 'idle' };

export function useUpdates(): UpdatesState {
  const [status, setStatus] = useState<UpdateStatus>(INITIAL);
  const [info, setInfo] = useState<UpdateInfo | null>(null);

  useEffect(() => {
    let active = true;

    // Subscribe before seeding: a transition that happens while the seed is in flight
    // must not be lost, and the `idle` guard below keeps it from being undone.
    const unsubscribe = api.updates.onStatus((next) => {
      if (active) setStatus(next);
    });

    void api.updates
      .getStatus()
      .then((seed) => {
        if (active) setStatus((current) => (current.kind === 'idle' ? seed : current));
      })
      // The next broadcast fills this in; there is nothing useful to say meanwhile.
      .catch(() => undefined);

    void api.updates
      .getInfo()
      .then((next) => {
        if (active) setInfo(next);
      })
      // Callers already treat `null` as "not known yet".
      .catch(() => undefined);

    return () => {
      active = false;
      unsubscribe();
    };
  }, []);

  const checkNow = useCallback(async (): Promise<void> => {
    try {
      setStatus(await api.updates.checkNow());
    } catch {
      // A check that could not even be started is still a failed check, and the
      // notice words that as the app's problem rather than the user's.
      setStatus({ kind: 'error', message: 'The update check could not be started.' });
    }
  }, []);

  const download = useCallback(async (): Promise<void> => {
    try {
      setStatus(await api.updates.download());
    } catch {
      // Leave the status alone: it is still `available`, so the button the user just
      // pressed is still there to press again — which is more use than an error line.
    }
  }, []);

  const installNow = useCallback(async (): Promise<void> => {
    try {
      await api.updates.installNow();
    } catch {
      // Success here means the app quits, so there is no UI left to report into.
      // A failure leaves the downloaded update in place for the next launch.
    }
  }, []);

  const openReleases = useCallback(async (): Promise<void> => {
    try {
      await api.updates.openReleases();
    } catch {
      // A shell call that opened nothing reads as "nothing happened", which is the
      // whole of the damage.
    }
  }, []);

  return { status, info, checkNow, download, installNow, openReleases };
}

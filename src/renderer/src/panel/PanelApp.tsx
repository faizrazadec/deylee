/**
 * The tray panel (340x470, frameless).
 *
 * Every number on screen comes from `liveTotals(snapshot, tick)` via `useSnapshot`,
 * never from a locally incremented counter, so the display stays honest across sleep,
 * clock changes and midnight rollover. Actions are fire-and-forget: the authoritative
 * update always arrives back as a broadcast snapshot.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';
import type { CSSProperties } from 'react';

import { formatClock, formatCompact, formatDateLong, todayKey } from '@shared/time';
import type {
  IdleChoice,
  IdlePrompt as IdlePromptPayload,
  Notice,
  PendingRecovery,
  RecoveryChoice,
  TimerState,
  WakeChoice,
  WakePrompt as WakePromptPayload,
} from '@shared/types';

import { ActionButton } from '@renderer/components/ActionButton';
import { Button } from '@renderer/components/Button';
import { Modal } from '@renderer/components/Modal';
import { ProgressBar } from '@renderer/components/ProgressBar';
import { TimerDisplay } from '@renderer/components/TimerDisplay';
import { usePlatformInfo } from '@renderer/hooks/usePlatformInfo';
import { usePrefs } from '@renderer/hooks/usePrefs';
import { useSnapshot } from '@renderer/hooks/useSnapshot';
import { useUpdates } from '@renderer/hooks/useUpdates';
import { api, cn } from '@renderer/lib/api';

import { IdlePrompt } from './IdlePrompt';
import { NoticeBanner } from './NoticeBanner';
import { RecoveryPrompt } from './RecoveryPrompt';
import { TodaySegments } from './TodaySegments';
import { WakePrompt } from './WakePrompt';

/**
 * `-webkit-app-region` is what makes a frameless window draggable, and csstype does
 * not declare it — so the property is widened here rather than casting the style away.
 */
interface AppRegionStyle extends CSSProperties {
  WebkitAppRegion: 'drag' | 'no-drag';
}

const DRAG: AppRegionStyle = { WebkitAppRegion: 'drag' };
const NO_DRAG: AppRegionStyle = { WebkitAppRegion: 'no-drag' };

const STATUS: Record<TimerState, { label: string; dot: string }> = {
  IDLE: { label: 'Idle', dot: 'bg-fg-faint' },
  RUNNING: { label: 'Running', dot: 'bg-work' },
  PAUSED: { label: 'Paused', dot: 'bg-break' },
  ENDED: { label: 'Day ended', dot: 'bg-accent' },
};

/**
 * Prompts arrive from three independent sources and must never stack: the head of
 * this queue is the one modal on screen. Each entry is keyed by its origin so a
 * re-broadcast — the panel reopens, the main process re-sends — cannot duplicate it.
 */
type QueuedPrompt =
  | { key: string; kind: 'recovery'; prompt: PendingRecovery }
  | { key: string; kind: 'idle'; prompt: IdlePromptPayload }
  | { key: string; kind: 'wake'; prompt: WakePromptPayload };

/**
 * Bridge calls answer with a snapshot that also arrives as a broadcast, so the
 * resolved value is redundant — but a rejection must not become an unhandled one.
 */
function fireAndForget(promise: Promise<unknown>): void {
  void promise.catch(() => undefined);
}

export function PanelApp() {
  const { snapshot, live, tick } = useSnapshot();
  const updates = useUpdates();
  const platform = usePlatformInfo();

  /**
   * Quitting normally lives in the tray menu. Where there is no tray — a desktop with
   * no StatusNotifierItem host, or a snap, which cannot show one at all — that menu
   * does not exist and the app has no way to be closed: every window hides rather than
   * quits, by design, so it would run until it was killed.
   */
  const showQuit = platform?.trayFallbackActive === true;

  // No preference is shown here, but `usePrefs` is what stamps the resolved theme on
  // <html>; without it an explicit light/dark choice would never reach this window.
  usePrefs();

  const [queue, setQueue] = useState<QueuedPrompt[]>([]);
  const [resolving, setResolving] = useState(false);
  const [notices, setNotices] = useState<Notice[]>([]);
  const [confirmingEndDay, setConfirmingEndDay] = useState(false);
  const [historyRevision, setHistoryRevision] = useState(0);

  const enqueue = useCallback((item: QueuedPrompt) => {
    // A prompt taking the screen invalidates any half-made decision underneath it:
    // answering the prompt must not reveal a stale confirmation the user has moved on from.
    setConfirmingEndDay(false);
    setQueue((current) =>
      current.some((queued) => queued.key === item.key) ? current : [...current, item],
    );
  }, []);

  useEffect(() => {
    let active = true;

    // A recovery prompt broadcast while this window was still loading would be lost,
    // so the held one is also pulled once on mount.
    fireAndForget(
      api.prompts.getRecovery().then((pending) => {
        if (!active || pending === null) return;
        enqueue({ key: `recovery:${pending.segment.id}`, kind: 'recovery', prompt: pending });
      }),
    );

    const offRecovery = api.prompts.onRecoveryPrompt((prompt) => {
      enqueue({ key: `recovery:${prompt.segment.id}`, kind: 'recovery', prompt });
    });
    const offIdle = api.prompts.onIdlePrompt((prompt) => {
      enqueue({ key: `idle:${prompt.id}`, kind: 'idle', prompt });
    });
    const offWake = api.prompts.onWakePrompt((prompt) => {
      enqueue({ key: `wake:${prompt.id}`, kind: 'wake', prompt });
    });

    return () => {
      active = false;
      offRecovery();
      offIdle();
      offWake();
    };
  }, [enqueue]);

  useEffect(
    () =>
      api.prompts.onNotice((notice) => {
        setNotices((current) =>
          current.some((existing) => existing.id === notice.id) ? current : [...current, notice],
        );
      }),
    [],
  );

  useEffect(() => api.history.onInvalidated(() => setHistoryRevision((n) => n + 1)), []);

  /**
   * Advance the queue whether the call succeeded or not: a failed resolution that
   * left its modal up would be a dead end, with no way back to the timer.
   */
  const resolveHead = useCallback((run: () => Promise<unknown>) => {
    setResolving(true);
    fireAndForget(
      run().finally(() => {
        setResolving(false);
        setQueue((current) => current.slice(1));
      }),
    );
  }, []);

  const resolveRecovery = useCallback(
    (choice: RecoveryChoice) => resolveHead(() => api.prompts.resolveRecovery(choice)),
    [resolveHead],
  );
  const resolveIdle = useCallback(
    (promptId: string, choice: IdleChoice) =>
      resolveHead(() => api.prompts.resolveIdle({ promptId, choice })),
    [resolveHead],
  );
  const resolveWake = useCallback(
    (promptId: string, choice: WakeChoice) =>
      resolveHead(() => api.prompts.resolveWake({ promptId, choice })),
    [resolveHead],
  );

  const dismissNotice = useCallback((id: string) => {
    setNotices((current) => current.filter((notice) => notice.id !== id));
    fireAndForget(api.prompts.dismissNotice(id));
  }, []);

  const handleStart = useCallback(() => fireAndForget(api.timer.start()), []);
  const handlePause = useCallback(() => fireAndForget(api.timer.pause()), []);
  const handleResume = useCallback(() => fireAndForget(api.timer.resume()), []);
  const handleEndDay = useCallback(() => {
    setConfirmingEndDay(false);
    fireAndForget(api.timer.endDay());
  }, []);

  const state: TimerState = snapshot?.state ?? 'IDLE';
  const status = STATUS[state];
  const date = snapshot?.date ?? todayKey(tick);
  const firstStartAt = snapshot === null ? null : snapshot.firstStartAt;
  const hasTarget = live.targetMs > 0;
  const canEndDay = state === 'RUNNING' || state === 'PAUSED';
  const activePrompt = queue.length > 0 ? queue[0] : null;

  /**
   * The only thing an update is ever allowed to do to this window. A tray app is open
   * all day, so a downloaded update waits in the footer as a link the user can ignore
   * for a week — it never takes focus, never interrupts the timer and never restarts
   * anything on its own. Every other update state lives in Settings.
   */
  const updateReady = updates.status.kind === 'downloaded' ? updates.status : null;

  // Closed totals move whenever a segment opens or closes, which makes them a
  // reliable "the stored rows changed" signal without refetching on each heartbeat.
  const segmentsRevision = useMemo(
    () =>
      [
        historyRevision,
        snapshot?.state ?? '',
        snapshot?.openSegment?.id ?? '',
        snapshot?.closedWorkedMs ?? 0,
        snapshot?.closedBreakMs ?? 0,
      ].join(':'),
    [historyRevision, snapshot],
  );

  return (
    <div className="flex h-full w-full flex-col overflow-hidden rounded-window border border-border bg-surface text-fg">
      <header style={DRAG} className="flex shrink-0 items-center justify-between gap-2 px-4 pt-3 pb-2">
        <span className="flex items-center gap-1.5 text-[0.6875rem] font-medium text-fg-muted">
          <span className={cn('size-2 rounded-full', status.dot)} aria-hidden="true" />
          {status.label}
        </span>
        <span className="truncate text-[0.6875rem] text-fg-faint">{formatDateLong(date)}</span>
      </header>

      <main className="flex min-h-0 flex-1 flex-col gap-3 px-4 pb-2">
        {notices.length > 0 && (
          <div style={NO_DRAG} className="flex shrink-0 flex-col gap-2">
            {notices.map((notice) => (
              <NoticeBanner key={notice.id} notice={notice} onDismiss={dismissNotice} />
            ))}
          </div>
        )}

        <div className="shrink-0 text-center">
          {/* docs/DESIGN.md §2: hero is 52px at weight 300 with -.02em tracking, and
              the seconds sit at half size, one contrast step down. The light weight is
              deliberate — at this size a semibold reads as an alarm. */}
          <TimerDisplay
            ms={live.workedMs}
            withSeconds
            splitSeconds
            className="block text-[52px] leading-none font-light tracking-[-0.02em] text-fg"
            secondsClassName="text-fg-dim"
          />
          <p className="mt-2 text-xs text-fg-muted">
            <span className="text-fg-faint">Break</span>{' '}
            <span className="tabular-nums">{formatCompact(live.breakMs)}</span>
            {firstStartAt !== null && (
              <>
                <span className="text-fg-faint"> · since </span>
                <span className="tabular-nums">{formatClock(firstStartAt)}</span>
              </>
            )}
          </p>
        </div>

        <div className="shrink-0 space-y-1.5">
          {hasTarget && <ProgressBar progress={live.targetProgress} />}
          <div className="flex items-baseline justify-between gap-2 text-[0.6875rem] tabular-nums text-fg-faint">
            <span>
              {hasTarget
                ? `${formatCompact(live.workedMs)} of ${formatCompact(live.targetMs)}`
                : `${formatCompact(live.workedMs)} worked today`}
            </span>
            {hasTarget && (
              <span>
                {live.remainingToTargetMs > 0
                  ? `${formatCompact(live.remainingToTargetMs)} left`
                  : 'Target met'}
              </span>
            )}
          </div>
        </div>

        <div style={NO_DRAG} className="flex shrink-0 items-center gap-2">
          {/* ActionButton is `w-full shrink-0`; the wrapper is what gives it a width
              to fill, so End Day can sit beside it without pushing it off-panel. */}
          <div className="min-w-0 flex-1">
            <ActionButton
              state={state}
              disabled={snapshot === null}
              onStart={handleStart}
              onPause={handlePause}
              onResume={handleResume}
            />
          </div>
          {canEndDay && (
            <Button variant="secondary" size="lg" onClick={() => setConfirmingEndDay(true)}>
              End day
            </Button>
          )}
        </div>

        <section className="flex min-h-0 flex-1 flex-col">
          <h2 className="shrink-0 pb-1.5 text-[0.625rem] font-medium tracking-wider text-fg-faint uppercase">
            Today
          </h2>
          <TodaySegments date={date} now={tick} revision={segmentsRevision} />
        </section>
      </main>

      <footer
        style={NO_DRAG}
        className="flex shrink-0 items-center justify-between border-t border-border px-2 py-1.5"
      >
        <Button variant="ghost" size="sm" onClick={() => fireAndForget(api.windows.open('history'))}>
          History
        </Button>
        <div className="flex min-w-0 items-center gap-1">
          {updateReady !== null && (
            <Button
              variant="ghost"
              size="sm"
              title={`Version ${updateReady.version} is ready`}
              onClick={() => fireAndForget(updates.installNow())}
            >
              Restart to update
            </Button>
          )}
          <Button
            variant="ghost"
            size="sm"
            onClick={() => fireAndForget(api.windows.open('settings'))}
          >
            Settings
          </Button>
          {showQuit && (
            <Button
              variant="ghost"
              size="sm"
              title="Quit Dayly — with no tray icon there is nowhere else to do this"
              onClick={() => fireAndForget(api.system.quit())}
            >
              Quit
            </Button>
          )}
        </div>
      </footer>

      {/* End Day finalises the day and sits right beside the primary action, so it
          is confirmed rather than fired on a stray click. */}
      <Modal
        open={confirmingEndDay && activePrompt === null}
        title="End the day?"
        onClose={() => setConfirmingEndDay(false)}
        footer={
          <>
            <Button variant="ghost" onClick={() => setConfirmingEndDay(false)}>
              Cancel
            </Button>
            <Button variant="danger" onClick={handleEndDay}>
              End day
            </Button>
          </>
        }
      >
        <p>
          This closes whatever is running and finalises{' '}
          <span className="font-medium tabular-nums text-fg">{formatCompact(live.workedMs)}</span>{' '}
          of work. You can still start again afterwards — the day simply reopens.
        </p>
      </Modal>

      {activePrompt !== null && activePrompt.kind === 'recovery' && (
        <RecoveryPrompt
          open
          prompt={activePrompt.prompt}
          busy={resolving}
          onResolve={resolveRecovery}
        />
      )}
      {activePrompt !== null && activePrompt.kind === 'idle' && (
        <IdlePrompt
          open
          prompt={activePrompt.prompt}
          busy={resolving}
          onResolve={(choice) => resolveIdle(activePrompt.prompt.id, choice)}
        />
      )}
      {activePrompt !== null && activePrompt.kind === 'wake' && (
        <WakePrompt
          open
          prompt={activePrompt.prompt}
          busy={resolving}
          onResolve={(choice) => resolveWake(activePrompt.prompt.id, choice)}
        />
      )}
    </div>
  );
}

/**
 * The floating mini-window (180x56, frameless, transparent, always-on-top).
 *
 * It is a glance surface, not a control panel: the live worked total in `H:MM`, a
 * state dot, and the one action the current state allows. Everything else lives in
 * the panel, which a double-click opens.
 *
 * The window is transparent, so nothing outside the card may paint — `mini-root`
 * is the hook `styles.css` uses to clear the document background.
 */

import { useCallback, useEffect } from 'react';
import type { CSSProperties } from 'react';

import { formatCompact } from '@shared/time';
import type { TimerState } from '@shared/types';

import { ActionButton } from '@renderer/components/ActionButton';
import { TimerDisplay } from '@renderer/components/TimerDisplay';
import { usePrefs } from '@renderer/hooks/usePrefs';
import { useSnapshot } from '@renderer/hooks/useSnapshot';
import { api, cn } from '@renderer/lib/api';

/**
 * `-webkit-app-region` is what makes a frameless window draggable, and csstype does
 * not declare it — so the property is widened here rather than casting the style away.
 */
interface AppRegionStyle extends CSSProperties {
  WebkitAppRegion: 'drag' | 'no-drag';
}

const DRAG: AppRegionStyle = { WebkitAppRegion: 'drag' };
const NO_DRAG: AppRegionStyle = { WebkitAppRegion: 'no-drag' };

/** A move produces a burst of events; only the settled position is worth an IPC call. */
const POSITION_SETTLE_MS = 200;

/** Colours match the panel's status dot so the two windows never disagree. */
const STATUS: Record<TimerState, { label: string; dot: string }> = {
  IDLE: { label: 'Idle', dot: 'bg-fg-faint' },
  RUNNING: { label: 'Running', dot: 'bg-work' },
  PAUSED: { label: 'Paused', dot: 'bg-break' },
  ENDED: { label: 'Day ended', dot: 'bg-accent' },
};

/** Bridge calls answer with a snapshot that also arrives as a broadcast, so the
 *  resolved value is redundant; a rejection must not become an unhandled one. */
function fireAndForget(promise: Promise<unknown>): void {
  void promise.catch(() => undefined);
}

/**
 * Report where the window ended up, so the main process can remember it per display.
 *
 * A drag region is moved by the OS, not by the page, so there is no `mousemove` to
 * follow — the position is read after the fact. `mouseup` covers a normal drag;
 * `resize` and `blur` are the safety net for the releases the renderer never sees
 * (the pointer ends over another window, or the window is moved for us).
 */
function useReportedPosition(): void {
  useEffect(() => {
    let timer: number | null = null;
    let reportedX = window.screenX;
    let reportedY = window.screenY;

    const flush = (): void => {
      timer = null;
      const x = window.screenX;
      const y = window.screenY;
      // Every click and every focus change fires this; only real moves are news.
      if (x === reportedX && y === reportedY) return;
      reportedX = x;
      reportedY = y;
      fireAndForget(api.windows.reportMiniMoved({ x, y }));
    };

    const schedule = (): void => {
      if (timer !== null) window.clearTimeout(timer);
      timer = window.setTimeout(flush, POSITION_SETTLE_MS);
    };

    window.addEventListener('mouseup', schedule);
    window.addEventListener('resize', schedule);
    window.addEventListener('blur', schedule);

    return () => {
      if (timer !== null) window.clearTimeout(timer);
      window.removeEventListener('mouseup', schedule);
      window.removeEventListener('resize', schedule);
      window.removeEventListener('blur', schedule);
    };
  }, []);
}

export function MiniApp() {
  const { snapshot, live } = useSnapshot();

  // No preference is shown here, but `usePrefs` is what stamps the resolved theme on
  // <html>; without it an explicit light/dark choice would never reach this window.
  usePrefs();
  useReportedPosition();

  const handleStart = useCallback(() => fireAndForget(api.timer.start()), []);
  const handlePause = useCallback(() => fireAndForget(api.timer.pause()), []);
  const handleResume = useCallback(() => fireAndForget(api.timer.resume()), []);
  const handleOpenPanel = useCallback(() => fireAndForget(api.windows.open('panel')), []);

  const state: TimerState = snapshot?.state ?? 'IDLE';
  const status = STATUS[state];

  return (
    <div
      className="mini-root h-screen w-screen overflow-hidden"
      style={DRAG}
      onDoubleClick={handleOpenPanel}
      title={`${status.label} · ${formatCompact(live.workedMs)} worked · ${formatCompact(live.breakMs)} break — double-click to open Dayly`}
    >
      <div className="flex h-full w-full items-center gap-2.5 rounded-xl border border-border bg-raised/80 px-3 backdrop-blur-xl">
        <span
          className={cn('size-2 shrink-0 rounded-full', status.dot)}
          role="img"
          aria-label={status.label}
        />
        <TimerDisplay
          ms={live.workedMs}
          // docs/DESIGN.md §5: mini timer is 22px at weight 400 — regular, not bold.
          className="min-w-0 flex-1 truncate text-[22px] leading-none font-normal"
        />
        {/* The button must opt out of the drag region or the click is swallowed by
            the window move; the double-click stops here for the same reason — a fast
            pause/resume must not also open the panel. */}
        <span
          style={NO_DRAG}
          className="flex shrink-0 items-center"
          onDoubleClick={(event) => event.stopPropagation()}
        >
          <ActionButton
            state={state}
            compact
            disabled={snapshot === null}
            onStart={handleStart}
            onPause={handlePause}
            onResume={handleResume}
          />
        </span>
      </div>
    </div>
  );
}

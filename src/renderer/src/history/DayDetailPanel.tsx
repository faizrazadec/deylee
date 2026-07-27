/**
 * The right-hand column: one day, its totals and its segments.
 *
 * Totals are recomputed here with `dayTotals` against the render tick instead of being
 * read from `DayDetail.totals`, because a day whose segment is still open was already
 * stale when the range was read. Every mutation is delegated upwards — this component
 * decides *what* the user asked for, never *how* it is persisted.
 */

import { dayTotals } from '@domain/duration';
import { MS_PER_MINUTE, formatClock, formatCompact, formatDateLong, todayKey } from '@shared/time';
import type { DateKey, DayDetail, Segment } from '@shared/types';

import { Button } from '@renderer/components/Button';
import { EmptyState } from '@renderer/components/EmptyState';
import { ProgressBar } from '@renderer/components/ProgressBar';
import { SegmentRow } from '@renderer/components/SegmentRow';
import { TimerDisplay } from '@renderer/components/TimerDisplay';
import { useTicker } from '@renderer/hooks/useTicker';

const NO_SEGMENTS: readonly Segment[] = [];

export interface DayDetailPanelProps {
  date: DateKey;
  /** `null` when nothing has ever been recorded on this day. */
  detail: DayDetail | null;
  /** The day's own target, falling back to the current preference for an unused day. */
  targetMinutes: number;
  onAddSegment: () => void;
  onEditSegment: (segment: Segment) => void;
  onDeleteSegment: (segment: Segment) => void;
}

export function DayDetailPanel({
  date,
  detail,
  targetMinutes,
  onAddSegment,
  onEditSegment,
  onDeleteSegment,
}: DayDetailPanelProps) {
  const now = useTicker(1000);

  const segments = detail?.segments ?? NO_SEGMENTS;
  const totals = dayTotals(segments, date, now);
  const targetMs = Math.max(0, targetMinutes) * MS_PER_MINUTE;
  const met = targetMs > 0 && totals.workedMs >= targetMs;

  return (
    <aside className="flex w-[340px] shrink-0 flex-col border-l border-border bg-raised">
      <header className="shrink-0 border-b border-border px-5 py-4">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-semibold text-fg">{formatDateLong(date)}</h2>
          {date === todayKey(now) ? (
            <span className="rounded-md border border-accent/30 bg-accent-soft px-1.5 py-0.5 text-[10px] font-medium text-accent">
              Today
            </span>
          ) : null}
        </div>

        <div className="mt-3 flex items-baseline gap-2">
          <TimerDisplay ms={totals.workedMs} className="text-[38px] leading-none font-light" />
          <span className={met ? 'text-xs text-work' : 'text-xs text-fg-muted'}>
            {targetMs === 0
              ? 'worked'
              : met
                ? `target met · +${formatCompact(totals.workedMs - targetMs)}`
                : `of ${formatCompact(targetMs)}`}
          </span>
        </div>

        {targetMs > 0 ? (
          <ProgressBar progress={totals.workedMs / targetMs} className="mt-3" />
        ) : null}

        <p className="mt-3 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-fg-faint tabular-nums">
          <span>
            {totals.firstStartAt === null ? '—' : formatClock(totals.firstStartAt)}
            {' – '}
            {totals.lastEndAt !== null
              ? formatClock(totals.lastEndAt)
              : totals.hasOpenSegment
                ? 'now'
                : '—'}
          </span>
          <span>
            {totals.segmentCount} {totals.segmentCount === 1 ? 'segment' : 'segments'}
          </span>
          <span>{formatCompact(totals.breakMs)} break</span>
        </p>
      </header>

      <div className="flex shrink-0 items-center justify-between gap-2 px-5 pt-4 pb-2">
        <h3 className="text-[10px] font-semibold tracking-[0.12em] text-fg-faint uppercase">
          Segments
        </h3>
        <Button size="sm" onClick={onAddSegment}>
          Add segment
        </Button>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-5 pb-5">
        {segments.length === 0 ? (
          <EmptyState
            title="Nothing on this day"
            description="Add a segment by hand to record time the timer missed."
          />
        ) : (
          <ul className="space-y-1">
            {segments.map((segment) => (
              <li key={segment.id}>
                <SegmentRow
                  segment={segment}
                  now={now}
                  onEdit={onEditSegment}
                  onDelete={onDeleteSegment}
                />
              </li>
            ))}
          </ul>
        )}
      </div>
    </aside>
  );
}

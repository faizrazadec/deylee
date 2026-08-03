/**
 * The month as rows instead of a grid.
 *
 * It covers the same densified range as the calendar so the two views never disagree
 * about which days exist, but runs newest first — scanning a log backwards from today
 * is what a list is for.
 */

import { useMemo } from 'react';

import { densifyRange } from '@domain/aggregate';
import { MS_PER_MINUTE, formatClock, formatCompact, formatDateLong } from '@shared/time';
import type { DateKey, DateRange, DayDetail } from '@shared/types';

import { cn } from '@renderer/lib/api';

/** Day · worked · break · first start · last end. */
const COLUMNS = 'grid grid-cols-[minmax(0,1fr)_5.5rem_5.5rem_4.5rem_4.5rem] items-center gap-3';

export interface ListViewProps {
  range: DateRange;
  days: readonly DayDetail[];
  today: DateKey;
  selected: DateKey;
  onSelect: (date: DateKey) => void;
}

export function ListView({ range, days, today, selected, onSelect }: ListViewProps) {
  const rows = useMemo(() => {
    const dense = densifyRange(range, days);
    return [...dense.entries()].reverse();
  }, [range, days]);

  return (
    <div>
      <div
        className={cn(
          COLUMNS,
          'border-b border-border px-3 pb-2 text-[10px] font-semibold tracking-[0.1em] text-fg-faint uppercase',
        )}
      >
        <span>Day</span>
        <span className="text-right">Worked</span>
        <span className="text-right">Break</span>
        <span className="text-right">First</span>
        <span className="text-right">Last</span>
      </div>

      <ul className="pt-1">
        {rows.map(([date, detail]) => (
          <li key={date}>
            <Row
              date={date}
              detail={detail}
              isToday={date === today}
              isSelected={date === selected}
              onSelect={onSelect}
            />
          </li>
        ))}
      </ul>
    </div>
  );
}

interface RowProps {
  date: DateKey;
  detail: DayDetail | null;
  isToday: boolean;
  isSelected: boolean;
  onSelect: (date: DateKey) => void;
}

function Row({ date, detail, isToday, isSelected, onSelect }: RowProps) {
  const totals = detail?.totals ?? null;
  const workedMs = totals?.workedMs ?? 0;
  const breakMs = totals?.breakMs ?? 0;
  const targetMs = (detail?.day.targetMinutes ?? 0) * MS_PER_MINUTE;
  const met = targetMs > 0 && workedMs >= targetMs;
  const tracked = workedMs > 0 || breakMs > 0;

  return (
    <button
      type="button"
      onClick={() => onSelect(date)}
      aria-pressed={isSelected}
      aria-current={isToday ? 'date' : undefined}
      className={cn(
        COLUMNS,
        'w-full rounded-lg px-3 py-2 text-left text-sm transition-colors duration-150',
        isSelected ? 'bg-accent-soft text-fg' : 'text-fg-muted hover:bg-hover',
      )}
    >
      <span className="flex min-w-0 items-center gap-2">
        <span className={cn('truncate', tracked ? 'text-fg' : 'text-fg-faint')}>
          {formatDateLong(date)}
        </span>
        {isToday ? (
          <span className="shrink-0 rounded-md border border-accent/30 bg-accent-soft px-1.5 py-0.5 text-[10px] font-medium text-accent">
            Today
          </span>
        ) : null}
      </span>

      <span className="flex items-center justify-end gap-1.5 tabular-nums">
        {met ? <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-work" /> : null}
        <span className={workedMs > 0 ? 'font-medium text-fg' : 'text-fg-faint'}>
          {workedMs > 0 ? formatCompact(workedMs) : '—'}
        </span>
      </span>

      <span className={cn('text-right tabular-nums', breakMs > 0 ? 'text-break' : 'text-fg-faint')}>
        {breakMs > 0 ? formatCompact(breakMs) : '—'}
      </span>

      <span className="text-right tabular-nums">
        {totals?.firstStartAt != null ? formatClock(totals.firstStartAt) : '—'}
      </span>

      <span className="text-right tabular-nums">
        {totals?.lastEndAt != null
          ? formatClock(totals.lastEndAt)
          : totals?.hasOpenSegment === true
            ? 'now'
            : '—'}
      </span>
    </button>
  );
}

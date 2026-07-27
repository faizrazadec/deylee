/**
 * The month grid.
 *
 * `densifyRange` guarantees one entry per calendar day, so the grid never has to
 * reason about which days happen to exist in the database — every cell is present and
 * a day with no row simply reads as empty. Leading and trailing blanks are computed
 * from `startOfWeek`, which is why the grid honours `weekStartsOn` without any
 * modulo arithmetic on raw weekday numbers.
 */

import { useMemo } from 'react';

import { densifyRange } from '@domain/aggregate';
import { MS_PER_MINUTE, daysBetween, formatCompact, formatDateLong, startOfWeek } from '@shared/time';
import type { WeekStart } from '@shared/time';
import type { DateKey, DateRange, DayDetail } from '@shared/types';

import { cn } from '@renderer/lib/api';

export interface CalendarViewProps {
  range: DateRange;
  days: readonly DayDetail[];
  weekStartsOn: WeekStart;
  today: DateKey;
  selected: DateKey;
  onSelect: (date: DateKey) => void;
}

interface Cell {
  date: DateKey;
  detail: DayDetail | null;
}

export function CalendarView({
  range,
  days,
  weekStartsOn,
  today,
  selected,
  onSelect,
}: CalendarViewProps) {
  const cells = useMemo<Cell[]>(() => {
    const dense = densifyRange(range, days);
    const out: Cell[] = [];
    for (const [date, detail] of dense) out.push({ date, detail });
    return out;
  }, [range, days]);

  const weekdays = useMemo(() => weekdayLabels(weekStartsOn), [weekStartsOn]);

  const lead = daysBetween(startOfWeek(range.from, weekStartsOn), range.from);
  const trail = (7 - ((lead + cells.length) % 7)) % 7;

  return (
    <div>
      <div className="grid grid-cols-7 gap-1.5 pb-2">
        {weekdays.map((label, column) => (
          <span
            key={(weekStartsOn + column) % 7}
            className={cn(
              'px-1 text-[10px] font-semibold tracking-[0.1em] uppercase',
              isWeekendColumn(weekStartsOn, column) ? 'text-fg-faint' : 'text-fg-muted',
            )}
          >
            {label}
          </span>
        ))}
      </div>

      <div className="grid grid-cols-7 gap-1.5">
        {Array.from({ length: lead }, (_unused, index) => (
          <div key={`lead-${index}`} aria-hidden className="h-[72px]" />
        ))}

        {cells.map((cell, index) => (
          <DayCell
            key={cell.date}
            cell={cell}
            weekend={isWeekendColumn(weekStartsOn, (lead + index) % 7)}
            isToday={cell.date === today}
            isSelected={cell.date === selected}
            onSelect={onSelect}
          />
        ))}

        {Array.from({ length: trail }, (_unused, index) => (
          <div key={`trail-${index}`} aria-hidden className="h-[72px]" />
        ))}
      </div>
    </div>
  );
}

interface DayCellProps {
  cell: Cell;
  weekend: boolean;
  isToday: boolean;
  isSelected: boolean;
  onSelect: (date: DateKey) => void;
}

function DayCell({ cell, weekend, isToday, isSelected, onSelect }: DayCellProps) {
  const workedMs = cell.detail?.totals.workedMs ?? 0;
  const targetMs = (cell.detail?.day.targetMinutes ?? 0) * MS_PER_MINUTE;
  const met = targetMs > 0 && workedMs >= targetMs;
  const progress = targetMs > 0 ? Math.min(1, workedMs / targetMs) : 0;
  const tracked = workedMs > 0;

  // Conflicting utilities in one class string resolve by stylesheet order, not by
  // the order they are written, so each visual axis picks exactly one class.
  const background = isSelected ? 'bg-accent-soft' : weekend ? 'bg-sunken' : 'bg-raised';
  const border = isSelected
    ? 'border-accent'
    : isToday
      ? 'border-accent/60'
      : 'border-border hover:border-border-strong';

  const label = `${formatDateLong(cell.date)} — ${
    tracked ? `${formatCompact(workedMs)} worked` : 'nothing tracked'
  }${met ? ', target met' : ''}`;

  return (
    <button
      type="button"
      onClick={() => onSelect(cell.date)}
      aria-pressed={isSelected}
      aria-current={isToday ? 'date' : undefined}
      aria-label={label}
      title={label}
      className={cn(
        'flex h-[72px] flex-col justify-between rounded-lg border p-2 text-left transition-colors duration-150',
        background,
        border,
      )}
    >
      <span
        className={cn(
          'text-[11px] tabular-nums',
          isToday ? 'font-semibold text-accent' : tracked ? 'text-fg-muted' : 'text-fg-faint',
        )}
      >
        {Number(cell.date.slice(8))}
      </span>

      <span className="flex items-center justify-between gap-1">
        <span
          className={cn('text-[13px] tabular-nums', tracked ? 'text-fg' : 'text-fg-faint')}
        >
          {tracked ? formatCompact(workedMs) : '—'}
        </span>
        {met ? <span aria-hidden className="size-1.5 shrink-0 rounded-full bg-work" /> : null}
      </span>

      <span className="block h-0.5 w-full overflow-hidden rounded-full bg-border">
        <span
          className={cn('block h-full rounded-full', met ? 'bg-work' : 'bg-accent')}
          style={{ width: `${progress * 100}%` }}
        />
      </span>
    </button>
  );
}

function isWeekendColumn(weekStartsOn: WeekStart, column: number): boolean {
  const dayOfWeek = (weekStartsOn + column) % 7;
  return dayOfWeek === 0 || dayOfWeek === 6;
}

/** Locale weekday abbreviations, rotated to start on `weekStartsOn`. */
function weekdayLabels(weekStartsOn: WeekStart): string[] {
  const out: string[] = [];
  for (let column = 0; column < 7; column += 1) {
    // 7 January 2024 was a Sunday, so the day-of-week index maps straight onto the
    // date and no runtime "find me a Sunday" search is needed.
    const dayOfWeek = (weekStartsOn + column) % 7;
    out.push(
      new Date(2024, 0, 7 + dayOfWeek, 12).toLocaleDateString(undefined, { weekday: 'short' }),
    );
  }
  return out;
}

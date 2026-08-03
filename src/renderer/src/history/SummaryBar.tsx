/**
 * The roll-up strip under the month header.
 *
 * Both figures are `RangeSummary` objects produced by the main process — the month
 * for the visible range and the week for the selected day. The week is read as its
 * own range rather than filtered out of the month, because a week that straddles a
 * month boundary would otherwise silently under-report.
 */

import { formatCompact } from '@shared/time';
import type { DateKey, RangeSummary } from '@shared/types';

export interface SummaryBarProps {
  /** The visible month, or `null` while it loads. */
  month: RangeSummary | null;
  /** The week containing the selected day, or `null` while it loads. */
  week: RangeSummary | null;
}

const PLACEHOLDER = '—';

export function SummaryBar({ month, week }: SummaryBarProps) {
  return (
    <div className="flex shrink-0 items-stretch border-b border-border bg-raised px-5 py-3">
      <Stat
        label="Month"
        value={month === null ? PLACEHOLDER : formatCompact(month.totalWorkedMs)}
        hint={month === null ? undefined : `${formatCompact(month.totalBreakMs)} break`}
      />
      <Stat
        label="Week"
        value={week === null ? PLACEHOLDER : formatCompact(week.totalWorkedMs)}
        hint={week === null ? undefined : weekLabel(week.range.from, week.range.to)}
      />
      <Stat
        label="Average day"
        value={month === null ? PLACEHOLDER : formatCompact(month.averageWorkedMsPerActiveDay)}
        hint="across days with work"
      />
      <Stat
        label="Days logged"
        value={month === null ? PLACEHOLDER : String(month.activeDayCount)}
      />
      <Stat
        label="Target met"
        value={month === null ? PLACEHOLDER : String(month.targetMetCount)}
        hint={month === null ? undefined : `of ${month.activeDayCount} logged`}
      />
    </div>
  );
}

interface StatProps {
  label: string;
  value: string;
  hint?: string;
}

function Stat({ label, value, hint }: StatProps) {
  return (
    <div className="flex min-w-0 flex-col gap-0.5 border-l border-border pr-6 pl-6 first:border-l-0 first:pl-0">
      <span className="text-[10px] font-semibold tracking-[0.12em] text-fg-faint uppercase">
        {label}
      </span>
      <span className="text-[15px] font-medium text-fg tabular-nums">{value}</span>
      {hint === undefined ? null : (
        <span className="truncate text-[11px] text-fg-faint tabular-nums">{hint}</span>
      )}
    </div>
  );
}

/** `20 – 26 Jul`, in the host locale's day/month order. */
function weekLabel(from: DateKey, to: DateKey): string {
  return `${shortDate(from)} – ${shortDate(to)}`;
}

function shortDate(date: DateKey): string {
  const [year, month, day] = date.split('-').map(Number);
  // Noon keeps the label on the intended day even where midnight does not exist.
  return new Date(year, month - 1, day, 12).toLocaleDateString(undefined, {
    day: 'numeric',
    month: 'short',
  });
}

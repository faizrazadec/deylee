/**
 * The History window (980x680).
 *
 * One month is in play at a time: `monthRange` defines the visible range, the main
 * process returns its `RangeSummary`, and both views plus the day panel read from that
 * single object — so the calendar and the list can never disagree.
 *
 * Nothing here patches loaded data after a mutation. A successful create/edit/delete
 * bumps `revision` and the range is read again, which is exactly what an
 * `onInvalidated` broadcast does, so an edit made in another window lands identically.
 */

import { useCallback, useEffect, useMemo, useState } from 'react';

import { monthRange, weekRange } from '@domain/aggregate';
import { hoursToMinutes } from '@domain/duration';
import {
  addDays,
  endOfMonth,
  formatClock,
  fromTimeInputValue,
  startOfDay,
  startOfMonth,
  todayKey,
} from '@shared/time';
import type { WeekStart } from '@shared/time';
import type { DateKey, DayDetail, ExportFormat, RangeSummary, Segment } from '@shared/types';

import { Button } from '@renderer/components/Button';
import { EmptyState } from '@renderer/components/EmptyState';
import { Modal } from '@renderer/components/Modal';
import { usePrefs } from '@renderer/hooks/usePrefs';
import { useTicker } from '@renderer/hooks/useTicker';
import { api, cn } from '@renderer/lib/api';

import { CalendarView } from './CalendarView';
import { DayDetailPanel } from './DayDetailPanel';
import { ListView } from './ListView';
import { SegmentEditor } from './SegmentEditor';
import { SummaryBar } from './SummaryBar';

type ViewMode = 'calendar' | 'list';

interface EditorTarget {
  date: DateKey;
  /** `null` opens the editor in create mode. */
  segment: Segment | null;
}

interface StatusMessage {
  tone: 'ok' | 'error';
  text: string;
}

/** Stable identity, so the views' memoised grids do not rebuild while data loads. */
const NO_DAYS: readonly DayDetail[] = [];

const VIEW_TAB = 'h-7 rounded-md px-3 text-xs font-medium transition-colors duration-150';

export function HistoryApp() {
  const { prefs } = usePrefs();
  // A minute is enough to keep "today" honest across midnight without repainting
  // the whole month every second; the day panel runs its own 1s tick.
  const today = todayKey(useTicker(60_000));

  const [anchor, setAnchor] = useState<DateKey>(() => startOfMonth(todayKey()));
  const [selected, setSelected] = useState<DateKey>(() => todayKey());
  const [view, setView] = useState<ViewMode>('calendar');
  const [revision, setRevision] = useState(0);

  const [summary, setSummary] = useState<RangeSummary | null>(null);
  const [weekSummary, setWeekSummary] = useState<RangeSummary | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);

  const [editor, setEditor] = useState<EditorTarget | null>(null);
  const [pendingDelete, setPendingDelete] = useState<Segment | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);

  const [exporting, setExporting] = useState<ExportFormat | null>(null);
  const [status, setStatus] = useState<StatusMessage | null>(null);

  // Until preferences arrive, Monday keeps the grid from re-laying out twice on a
  // Sunday-start machine any more often than a Monday-start one.
  const weekStartsOn: WeekStart = prefs?.weekStartsOn ?? 1;

  const range = useMemo(() => monthRange(anchor), [anchor]);
  const week = useMemo(() => weekRange(selected, weekStartsOn), [selected, weekStartsOn]);

  useEffect(() => api.history.onInvalidated(() => setRevision((n) => n + 1)), []);

  useEffect(() => {
    let active = true;
    void api.history
      .getRange(range)
      .then((next) => {
        if (!active) return;
        setSummary(next);
        setLoadFailed(false);
      })
      .catch(() => {
        if (!active) return;
        setSummary(null);
        setLoadFailed(true);
      });
    return () => {
      active = false;
    };
  }, [range, revision]);

  // The selected week is read as its own range rather than filtered out of the month,
  // because a week that straddles a month boundary would otherwise under-report.
  useEffect(() => {
    let active = true;
    void api.history
      .getRange(week)
      .then((next) => {
        if (active) setWeekSummary(next);
      })
      .catch(() => {
        if (active) setWeekSummary(null);
      });
    return () => {
      active = false;
    };
  }, [week, revision]);

  const goToMonth = useCallback((monthStart: DateKey) => {
    setAnchor(monthStart);
    setStatus(null);
    // The selection always stays inside the visible month, which is what lets the day
    // panel read its detail straight out of the loaded summary.
    const now = todayKey();
    setSelected(now >= monthStart && now <= endOfMonth(monthStart) ? now : monthStart);
  }, []);

  const goPrevious = useCallback(
    () => goToMonth(startOfMonth(addDays(anchor, -1))),
    [anchor, goToMonth],
  );
  const goNext = useCallback(
    () => goToMonth(startOfMonth(addDays(endOfMonth(anchor), 1))),
    [anchor, goToMonth],
  );
  const goToday = useCallback(() => goToMonth(startOfMonth(todayKey())), [goToMonth]);

  const selectedDetail = useMemo(
    () => summary?.days.find((detail) => detail.day.date === selected) ?? null,
    [summary, selected],
  );

  const openCreate = useCallback(() => setEditor({ date: selected, segment: null }), [selected]);
  const openEdit = useCallback(
    (segment: Segment) => setEditor({ date: selected, segment }),
    [selected],
  );
  const requestDelete = useCallback((segment: Segment) => {
    setDeleteError(null);
    setPendingDelete(segment);
  }, []);

  const handleSaved = useCallback(
    (detail: DayDetail) => {
      setEditor(null);
      setRevision((n) => n + 1);
      // An overnight segment can be split onto a day the current month does not show;
      // following it out of the range would strand the panel.
      if (detail.day.date >= range.from && detail.day.date <= range.to) {
        setSelected(detail.day.date);
      }
    },
    [range],
  );

  const confirmDelete = useCallback(() => {
    const segment = pendingDelete;
    if (segment === null) return;

    setDeleting(true);
    setDeleteError(null);
    void api.history
      .deleteSegment(segment.id)
      .then((result) => {
        if (result.ok) {
          setPendingDelete(null);
          setRevision((n) => n + 1);
        } else {
          setDeleteError(result.message);
        }
        setDeleting(false);
      })
      .catch(() => {
        setDeleteError('The segment could not be deleted.');
        setDeleting(false);
      });
  }, [pendingDelete]);

  const runExport = useCallback(
    (format: ExportFormat) => {
      setExporting(format);
      setStatus(null);
      void api.history
        .exportData({ format, range })
        .then((result) => {
          if (result.ok) {
            setStatus({ tone: 'ok', text: `Saved to ${result.path}` });
          } else if (!result.cancelled) {
            setStatus({ tone: 'error', text: result.message });
          }
          // A cancelled save dialog is a normal outcome and is reported nowhere.
          setExporting(null);
        })
        .catch(() => {
          setStatus({ tone: 'error', text: 'The export could not be written.' });
          setExporting(null);
        });
    },
    [range],
  );

  const days = summary?.days ?? NO_DAYS;
  const monthIsEmpty = summary !== null && summary.days.length === 0;
  const targetMinutes =
    selectedDetail?.day.targetMinutes ?? hoursToMinutes(prefs?.dailyTargetHours ?? 0);
  // A new segment starts where the day left off; failing that, at a plausible 09:00.
  const defaultStartAt =
    selectedDetail?.totals.lastEndAt ?? fromTimeInputValue(selected, '09:00') ?? startOfDay(selected);

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden bg-surface text-fg">
      <header className="flex shrink-0 items-center gap-3 border-b border-border bg-raised px-5 py-3">
        <div className="flex items-center gap-1">
          <Button size="sm" onClick={goPrevious} aria-label="Previous month" title="Previous month">
            <ChevronIcon direction="left" />
          </Button>
          <Button size="sm" onClick={goNext} aria-label="Next month" title="Next month">
            <ChevronIcon direction="right" />
          </Button>
        </div>

        <h1 className="text-[17px] font-medium text-fg">{monthLabel(anchor)}</h1>

        <Button variant="ghost" size="sm" onClick={goToday}>
          Today
        </Button>

        <div className="ml-auto flex items-center gap-2">
          <div
            role="group"
            aria-label="View"
            className="flex items-center gap-0.5 rounded-lg border border-border bg-sunken p-0.5"
          >
            <button
              type="button"
              aria-pressed={view === 'calendar'}
              onClick={() => setView('calendar')}
              className={cn(
                VIEW_TAB,
                view === 'calendar' ? 'bg-raised text-fg' : 'text-fg-muted hover:text-fg',
              )}
            >
              Calendar
            </button>
            <button
              type="button"
              aria-pressed={view === 'list'}
              onClick={() => setView('list')}
              className={cn(
                VIEW_TAB,
                view === 'list' ? 'bg-raised text-fg' : 'text-fg-muted hover:text-fg',
              )}
            >
              List
            </button>
          </div>

          <Button size="sm" onClick={() => runExport('csv')} disabled={exporting !== null}>
            Export CSV
          </Button>
          <Button size="sm" onClick={() => runExport('json')} disabled={exporting !== null}>
            Export JSON
          </Button>
        </div>
      </header>

      {status === null ? null : (
        <div
          role="status"
          className={cn(
            'flex shrink-0 items-center gap-3 border-b px-5 py-2 text-xs',
            status.tone === 'ok'
              ? 'border-border bg-sunken text-fg-muted'
              : 'border-danger/30 bg-danger-soft text-danger',
          )}
        >
          <span className="min-w-0 flex-1 truncate" title={status.text}>
            {status.text}
          </span>
          <Button variant="ghost" size="sm" onClick={() => setStatus(null)}>
            Dismiss
          </Button>
        </div>
      )}

      <SummaryBar month={summary} week={weekSummary} />

      <main className="flex min-h-0 flex-1">
        <section className="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-5 py-4">
          {loadFailed ? (
            <EmptyState
              title="History could not be read"
              description="Dayly could not reach its local database. Close and reopen this window to try again."
            />
          ) : (
            <>
              {monthIsEmpty ? (
                <EmptyState
                  title={`Nothing tracked in ${monthLabel(anchor)}`}
                  description="Days appear here once you track time. You can still add a segment by hand from the day panel."
                />
              ) : null}

              {view === 'calendar' ? (
                <CalendarView
                  range={range}
                  days={days}
                  weekStartsOn={weekStartsOn}
                  today={today}
                  selected={selected}
                  onSelect={setSelected}
                />
              ) : null}

              {view === 'list' && !monthIsEmpty ? (
                <ListView
                  range={range}
                  days={days}
                  today={today}
                  selected={selected}
                  onSelect={setSelected}
                />
              ) : null}
            </>
          )}
        </section>

        <DayDetailPanel
          date={selected}
          detail={selectedDetail}
          targetMinutes={targetMinutes}
          onAddSegment={openCreate}
          onEditSegment={openEdit}
          onDeleteSegment={requestDelete}
        />
      </main>

      {editor === null ? null : (
        <SegmentEditor
          date={editor.date}
          segment={editor.segment}
          defaultStartAt={defaultStartAt}
          onClose={() => setEditor(null)}
          onSaved={handleSaved}
        />
      )}

      {pendingDelete === null ? null : (
        <Modal
          open
          title="Delete this segment?"
          onClose={deleting ? undefined : () => setPendingDelete(null)}
          footer={
            <>
              <Button variant="ghost" onClick={() => setPendingDelete(null)} disabled={deleting}>
                Cancel
              </Button>
              <Button variant="danger" onClick={confirmDelete} disabled={deleting}>
                Delete
              </Button>
            </>
          }
        >
          <p>
            This removes the {pendingDelete.type} segment from{' '}
            <span className="tabular-nums">{formatClock(pendingDelete.startedAt)}</span> to{' '}
            <span className="tabular-nums">
              {pendingDelete.endedAt === null ? 'now' : formatClock(pendingDelete.endedAt)}
            </span>
            . The time it recorded is gone for good.
          </p>
          {deleteError === null ? null : (
            <p
              role="alert"
              className="mt-3 rounded-lg border border-danger/30 bg-danger-soft px-3 py-2 text-[11px] text-danger"
            >
              {deleteError}
            </p>
          )}
        </Modal>
      )}
    </div>
  );
}

/** `July 2026`, in the host locale. */
function monthLabel(monthStart: DateKey): string {
  const [year, month] = monthStart.split('-').map(Number);
  return new Date(year, month - 1, 1, 12).toLocaleDateString(undefined, {
    month: 'long',
    year: 'numeric',
  });
}

function ChevronIcon({ direction }: { direction: 'left' | 'right' }) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      {direction === 'left' ? (
        <path d="M10.2 2.3a.8.8 0 0 1 0 1.1L5.6 8l4.6 4.6a.8.8 0 1 1-1.1 1.1L3.9 8.6a.8.8 0 0 1 0-1.2l5.2-5.1a.8.8 0 0 1 1.1 0Z" />
      ) : (
        <path d="M5.8 2.3a.8.8 0 0 0 0 1.1L10.4 8l-4.6 4.6a.8.8 0 1 0 1.1 1.1l5.2-5.1a.8.8 0 0 0 0-1.2L6.9 2.3a.8.8 0 0 0-1.1 0Z" />
      )}
    </svg>
  );
}

/**
 * Create or edit one segment.
 *
 * The two `<input type="time">` values are combined with the day's `DateKey` into
 * instants and sent as-is. Validation — overlap, zero length, a reversed range — is the
 * main process's job, and the `MutationResult` it returns is what the user reads, so
 * nothing is "corrected" here to make a request succeed.
 *
 * The single interpretation made locally: an end time earlier than the start means the
 * segment runs past midnight, so the end instant lands on the next day. That is stated
 * in the form rather than applied silently, because it is a guess about intent.
 */

import { useState } from 'react';
import type { FormEvent } from 'react';

import { MS_PER_HOUR, addDays, formatDateLong, fromTimeInputValue, toTimeInputValue } from '@shared/time';
import type {
  DateKey,
  DayDetail,
  EpochMs,
  MutationResult,
  Segment,
  SegmentType,
} from '@shared/types';

import { Button } from '@renderer/components/Button';
import { Modal } from '@renderer/components/Modal';
import { api, cn } from '@renderer/lib/api';

const FIELD =
  'h-9 w-full rounded-lg border border-border bg-surface px-2.5 text-sm text-fg ' +
  'transition-colors duration-150 outline-none focus:border-accent';

const LABEL = 'flex flex-col gap-1.5 text-[11px] font-medium text-fg-muted';

const TYPE_TAB = 'h-7 flex-1 rounded-md text-xs font-medium transition-colors duration-150';

const TYPES: readonly SegmentType[] = ['work', 'break'];

export interface SegmentEditorProps {
  /** The day the segment starts on. */
  date: DateKey;
  /** `null` creates a new segment on `date`. */
  segment: Segment | null;
  /** Where a new segment's start defaults to — the day's last end, or 09:00 local. */
  defaultStartAt: EpochMs;
  onClose: () => void;
  onSaved: (detail: DayDetail) => void;
}

export function SegmentEditor({
  date,
  segment,
  defaultStartAt,
  onClose,
  onSaved,
}: SegmentEditorProps) {
  const isNew = segment === null;
  const isOpenSegment = segment !== null && segment.endedAt === null;

  const [type, setType] = useState<SegmentType>(segment?.type ?? 'work');
  const [start, setStart] = useState(() => toTimeInputValue(segment?.startedAt ?? defaultStartAt));
  const [end, setEnd] = useState(() => {
    if (segment === null) return toTimeInputValue(defaultStartAt + MS_PER_HOUR);
    return segment.endedAt === null ? '' : toTimeInputValue(segment.endedAt);
  });
  const [note, setNote] = useState(segment?.note ?? '');
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  // Resolved on every render so the midnight notice appears while the user types,
  // from exactly the same computation that the save uses.
  const preview = resolveInstants(date, start, end, isOpenSegment);
  const overnight = preview.ok && preview.overnight;

  const clearError = (): void => setError(null);

  const submit = (): void => {
    if (saving) return;

    const resolved = resolveInstants(date, start, end, isOpenSegment);
    if (!resolved.ok) {
      setError(resolved.message);
      return;
    }

    const trimmed = note.trim();
    const payloadNote = trimmed.length === 0 ? null : trimmed;

    let request: Promise<MutationResult<DayDetail>>;
    if (segment === null) {
      const endedAt = resolved.endedAt;
      if (endedAt === null) {
        setError('Enter an end time.');
        return;
      }
      request = api.history.createSegment({
        date,
        input: { type, startedAt: resolved.startedAt, endedAt, note: payloadNote },
      });
    } else {
      request = api.history.updateSegment({
        id: segment.id,
        type,
        startedAt: resolved.startedAt,
        endedAt: resolved.endedAt,
        note: payloadNote,
      });
    }

    setSaving(true);
    setError(null);

    void request
      .then((result) => {
        // A rejected mutation keeps the form open with its reason attached: overlap and
        // invalid-range errors are only ever reported this way.
        if (result.ok) {
          onSaved(result.value);
          return;
        }
        setError(result.message);
        setSaving(false);
      })
      .catch(() => {
        setError('The segment could not be saved.');
        setSaving(false);
      });
  };

  const onSubmit = (event: FormEvent<HTMLFormElement>): void => {
    event.preventDefault();
    submit();
  };

  return (
    <Modal
      open
      title={isNew ? 'Add segment' : 'Edit segment'}
      onClose={saving ? undefined : onClose}
      footer={
        <>
          <Button variant="ghost" onClick={onClose} disabled={saving}>
            Cancel
          </Button>
          <Button variant="primary" onClick={submit} disabled={saving}>
            {isNew ? 'Add segment' : 'Save changes'}
          </Button>
        </>
      }
    >
      <form onSubmit={onSubmit} className="flex flex-col gap-4">
        <p className="text-[11px] text-fg-faint">{formatDateLong(date)}</p>

        <div className="flex flex-col gap-1.5">
          <span className="text-[11px] font-medium text-fg-muted">Type</span>
          <div
            role="group"
            aria-label="Segment type"
            className="flex gap-0.5 rounded-lg border border-border bg-sunken p-0.5"
          >
            {TYPES.map((candidate) => (
              <button
                key={candidate}
                type="button"
                aria-pressed={type === candidate}
                onClick={() => {
                  setType(candidate);
                  clearError();
                }}
                className={cn(
                  TYPE_TAB,
                  type === candidate
                    ? candidate === 'work'
                      ? 'bg-work-soft text-work'
                      : 'bg-break-soft text-break'
                    : 'text-fg-muted hover:text-fg',
                )}
              >
                {candidate === 'work' ? 'Work' : 'Break'}
              </button>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-2 gap-3">
          <label className={LABEL}>
            Start
            <input
              type="time"
              value={start}
              onChange={(event) => {
                setStart(event.target.value);
                clearError();
              }}
              className={cn(FIELD, 'tabular-nums')}
            />
          </label>

          <label className={LABEL}>
            End
            <input
              type="time"
              value={end}
              onChange={(event) => {
                setEnd(event.target.value);
                clearError();
              }}
              className={cn(FIELD, 'tabular-nums')}
            />
          </label>
        </div>

        {overnight ? (
          <p className="rounded-lg border border-border bg-sunken px-3 py-2 text-[11px] leading-relaxed text-fg-muted">
            The end time is before the start, so this segment is treated as running past
            midnight and ends on {formatDateLong(addDays(date, 1))}.
          </p>
        ) : null}

        {isOpenSegment && end === '' ? (
          <p className="rounded-lg border border-accent/30 bg-accent-soft px-3 py-2 text-[11px] leading-relaxed text-fg-muted">
            This segment is still running. Leave the end time empty to keep it open, or set
            one to close it here.
          </p>
        ) : null}

        <label className={LABEL}>
          Note <span className="font-normal text-fg-faint">(optional)</span>
          <input
            type="text"
            value={note}
            maxLength={200}
            placeholder="What was this time for?"
            onChange={(event) => {
              setNote(event.target.value);
              clearError();
            }}
            className={FIELD}
          />
        </label>

        {error === null ? null : (
          <p
            role="alert"
            className="rounded-lg border border-danger/30 bg-danger-soft px-3 py-2 text-[11px] leading-relaxed text-danger"
          >
            {error}
          </p>
        )}

        {/* The footer's Save button lives outside this element, so the form needs a
            default button of its own for Enter to submit from a field. */}
        <button type="submit" className="hidden" tabIndex={-1} />
      </form>
    </Modal>
  );
}

type Resolved =
  | { ok: true; startedAt: EpochMs; endedAt: EpochMs | null; overnight: boolean }
  | { ok: false; message: string };

/**
 * Turn the form's two local times into instants on `date`.
 *
 * `allowOpenEnd` exists for editing the segment that is currently running: an empty end
 * keeps it open rather than being an error.
 */
function resolveInstants(
  date: DateKey,
  start: string,
  end: string,
  allowOpenEnd: boolean,
): Resolved {
  const startedAt = fromTimeInputValue(date, start);
  if (startedAt === null) return { ok: false, message: 'Enter a start time as HH:MM.' };

  if (end === '') {
    if (allowOpenEnd) return { ok: true, startedAt, endedAt: null, overnight: false };
    return { ok: false, message: 'Enter an end time as HH:MM.' };
  }

  const sameDay = fromTimeInputValue(date, end);
  if (sameDay === null) return { ok: false, message: 'Enter an end time as HH:MM.' };

  // Equal instants are *not* nudged onto the next day — a zero-length segment is a real
  // mistake, and the main process names it better than a guess would.
  if (sameDay >= startedAt) return { ok: true, startedAt, endedAt: sameDay, overnight: false };

  const nextDay = fromTimeInputValue(addDays(date, 1), end);
  if (nextDay === null) return { ok: false, message: 'Enter an end time as HH:MM.' };
  return { ok: true, startedAt, endedAt: nextDay, overnight: true };
}

import { spanDuration } from '@domain/duration';
import { formatClock, formatCompact } from '@shared/time';
import type { Segment } from '@shared/types';
import { cn } from '@renderer/lib/api';

const ICON_BUTTON =
  'flex size-6 items-center justify-center rounded-md text-fg-faint transition-colors ' +
  'hover:bg-sunken hover:text-fg focus-visible:outline-2 focus-visible:outline-offset-1 ' +
  'focus-visible:outline-accent';

export interface SegmentRowProps {
  segment: Segment;
  now: number;
  onEdit?: (segment: Segment) => void;
  onDelete?: (segment: Segment) => void;
}

export function SegmentRow({ segment, now, onEdit, onDelete }: SegmentRowProps) {
  const isWork = segment.type === 'work';
  const isOpen = segment.endedAt === null;
  const duration = spanDuration(segment, now);
  const hasActions = onEdit !== undefined || onDelete !== undefined;

  return (
    <div
      className={cn(
        'group flex items-center gap-2.5 rounded-lg border bg-raised px-2.5 py-2',
        'transition-colors duration-150 hover:bg-hover',
        isOpen ? 'border-accent/40' : 'border-border',
      )}
    >
      <span
        className={cn(
          'shrink-0 rounded-md border px-1.5 py-0.5 text-[0.6875rem] font-medium tracking-wide',
          isWork
            ? 'border-work/25 bg-work-soft text-work'
            : 'border-break/25 bg-break-soft text-break',
        )}
      >
        {isWork ? 'Work' : 'Break'}
      </span>

      <span className="flex min-w-0 items-baseline gap-1 text-sm tabular-nums text-fg-muted">
        <span>{formatClock(segment.startedAt)}</span>
        <span className="text-fg-faint">–</span>
        {segment.endedAt === null ? (
          <span className="font-medium text-accent">now</span>
        ) : (
          <span>{formatClock(segment.endedAt)}</span>
        )}
      </span>

      {segment.note === null || segment.note === '' ? null : (
        <span className="min-w-0 truncate text-xs text-fg-faint" title={segment.note}>
          {segment.note}
        </span>
      )}

      <span className="ml-auto shrink-0 text-sm font-medium tabular-nums text-fg">
        {formatCompact(duration)}
      </span>

      {/* Hidden until the row is hovered or focused so a long day stays quiet. */}
      {hasActions ? (
        <span className="flex shrink-0 items-center gap-0.5 opacity-0 transition-opacity duration-150 group-hover:opacity-100 focus-within:opacity-100">
          {onEdit === undefined ? null : (
            <button
              type="button"
              onClick={() => onEdit(segment)}
              aria-label="Edit segment"
              title="Edit segment"
              className={ICON_BUTTON}
            >
              <PencilIcon />
            </button>
          )}
          {onDelete === undefined ? null : (
            <button
              type="button"
              onClick={() => onDelete(segment)}
              aria-label="Delete segment"
              title="Delete segment"
              className={cn(ICON_BUTTON, 'hover:bg-danger-soft hover:text-danger')}
            >
              <TrashIcon />
            </button>
          )}
        </span>
      ) : null}
    </div>
  );
}

function PencilIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      <path d="M11.4 1.9a1.4 1.4 0 0 1 2 0l.7.7a1.4 1.4 0 0 1 0 2l-.9.9-2.7-2.7.9-.9ZM9.6 3.7l2.7 2.7-6.2 6.2-3.2.5.5-3.2 6.2-6.2Z" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      <path d="M6.2 1.6h3.6a.8.8 0 0 1 .8.8v.7h2.6a.7.7 0 0 1 0 1.4h-.4l-.6 8.1a1.6 1.6 0 0 1-1.6 1.5H5.4a1.6 1.6 0 0 1-1.6-1.5l-.6-8.1h-.4a.7.7 0 0 1 0-1.4h2.6v-.7a.8.8 0 0 1 .8-.8Zm.6 1.5h2.4v-.1H6.8v.1ZM6.5 5.7a.6.6 0 0 0-.6.6l.2 5.4a.6.6 0 0 0 1.2 0l-.2-5.4a.6.6 0 0 0-.6-.6Zm3 0a.6.6 0 0 0-.6.6l-.2 5.4a.6.6 0 0 0 1.2 0l.2-5.4a.6.6 0 0 0-.6-.6Z" />
    </svg>
  );
}

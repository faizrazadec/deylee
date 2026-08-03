/**
 * A one-off message from the main process — today only the Linux "no tray host"
 * fallback. It is a banner rather than a modal because it is informational: it must
 * never stand between the user and the timer.
 */

import type { Notice } from '@shared/types';

import { cn } from '@renderer/lib/api';

export interface NoticeBannerProps {
  notice: Notice;
  onDismiss: (id: string) => void;
}

const TONE: Record<Notice['level'], string> = {
  info: 'border-accent/30 bg-accent-soft',
  warning: 'border-break/30 bg-break-soft',
};

export function NoticeBanner({ notice, onDismiss }: NoticeBannerProps) {
  return (
    <div
      role="status"
      className={cn(
        'flex items-start gap-2 rounded-lg border px-2.5 py-2 text-xs text-fg',
        TONE[notice.level],
      )}
    >
      <div className="min-w-0 flex-1">
        <p className="font-medium">{notice.title}</p>
        <p className="mt-0.5 leading-snug text-fg-muted">{notice.body}</p>
      </div>
      <button
        type="button"
        aria-label={`Dismiss: ${notice.title}`}
        title="Dismiss"
        onClick={() => onDismiss(notice.id)}
        className="-mt-0.5 -mr-0.5 shrink-0 rounded-md p-1 text-fg-faint transition-colors hover:bg-hover hover:text-fg"
      >
        <svg viewBox="0 0 12 12" aria-hidden className="size-3">
          <path
            d="M2.6 2.6 9.4 9.4M9.4 2.6 2.6 9.4"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinecap="round"
            fill="none"
          />
        </svg>
      </button>
    </div>
  );
}

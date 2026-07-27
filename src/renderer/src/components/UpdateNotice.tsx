/**
 * One quiet line describing where an update has got to.
 *
 * An update is the app's errand, not the user's, so this is deliberately the least
 * loud thing on screen: no modal, no colour alarm, no animation, no badge. It is a
 * sentence and at most one thing to press. The running green is reserved for the
 * running state alone and never appears here — not even when an update is ready.
 *
 * A failed check is styled *down* rather than up: the network is not the user's
 * problem to solve, and a red line would ask them to treat it as one.
 */

import type { UpdateInfo, UpdateStatus } from '@shared/types';

import { Button } from '@renderer/components/Button';
import { cn } from '@renderer/lib/api';

interface UpdateNoticeHandlers {
  onCheck: () => void;
  onDownload: () => void;
  onInstall: () => void;
  onOpenReleases: () => void;
}

export interface UpdateNoticeProps extends UpdateNoticeHandlers {
  status: UpdateStatus;
  /** `null` until the main process has answered; treated as "self-update unknown". */
  info: UpdateInfo | null;
  /** Right-aligns the line so it can sit in the control slot of a settings row. */
  compact?: boolean;
}

/**
 * A `link` is for leaving the app — it promises a browser, not an install. A `button`
 * is for something Dayly does itself. Keeping them visually distinct is the only
 * signal the macOS and .deb builds get that the update is theirs to finish.
 */
type NoticeAction =
  | { kind: 'button'; label: string; run: () => void }
  | { kind: 'link'; label: string; run: () => void };

interface NoticeView {
  message: string;
  /** `null` for the states you can only wait out. */
  action: NoticeAction | null;
  /** Drops a contrast step, for lines the user is not expected to act on. */
  quiet: boolean;
}

/** Downloads report an unclamped float; the line only ever shows whole percent. */
function percentLabel(percent: number): string {
  if (!Number.isFinite(percent)) return '0';
  return String(Math.min(100, Math.max(0, Math.round(percent))));
}

function describe(
  status: UpdateStatus,
  info: UpdateInfo | null,
  handlers: UpdateNoticeHandlers,
): NoticeView {
  const check: NoticeAction = { kind: 'button', label: 'Check now', run: handlers.onCheck };
  const releases: NoticeAction = {
    kind: 'link',
    label: 'Open Releases',
    run: handlers.onOpenReleases,
  };

  switch (status.kind) {
    case 'idle':
      return { message: 'Not checked yet', action: check, quiet: true };

    case 'checking':
      return { message: 'Checking for updates…', action: null, quiet: true };

    case 'up-to-date':
      return {
        message: info === null ? 'Up to date' : `Up to date · v${info.currentVersion}`,
        action: check,
        quiet: false,
      };

    case 'available':
      return {
        message: `Version ${status.version} is available`,
        // Offering a Download button on a build that cannot install it would be a
        // promise the platform will not keep, so it becomes the Releases page instead.
        action:
          info !== null && info.canAutoUpdate
            ? { kind: 'button', label: 'Download', run: handlers.onDownload }
            : releases,
        quiet: false,
      };

    case 'downloading':
      return {
        message: `Downloading… ${percentLabel(status.percent)}%`,
        action: null,
        quiet: true,
      };

    case 'downloaded':
      return {
        message: `Version ${status.version} is ready`,
        action: { kind: 'button', label: 'Restart to update', run: handlers.onInstall },
        quiet: false,
      };

    case 'manual':
      return {
        message: `Version ${status.version} is available — this build can’t install it for you`,
        action: releases,
        quiet: false,
      };

    case 'unsupported':
      return { message: status.reason, action: releases, quiet: true };

    case 'error':
      // The stored message is diagnostic, not something to read at a glance; it
      // stays in the tooltip and the line says only what the user needs to know.
      return {
        message: 'Couldn’t check for updates',
        action: { kind: 'button', label: 'Try again', run: handlers.onCheck },
        quiet: true,
      };
  }
}

export function UpdateNotice({
  status,
  info,
  onCheck,
  onDownload,
  onInstall,
  onOpenReleases,
  compact = false,
}: UpdateNoticeProps) {
  const view = describe(status, info, { onCheck, onDownload, onInstall, onOpenReleases });
  const detail = status.kind === 'error' ? status.message : undefined;

  return (
    <div
      role="status"
      className={cn(
        'flex items-center gap-2.5 text-[0.71875rem] leading-snug',
        compact ? 'justify-end text-right' : 'w-full justify-between',
      )}
    >
      <span
        title={detail}
        className={cn(
          'min-w-0',
          // The longest line — a version that has to be installed by hand — would
          // otherwise push the action out of a 560px settings window; it wraps instead.
          compact && 'max-w-[19rem]',
          view.quiet ? 'text-fg-faint' : 'text-fg-muted',
        )}
      >
        {view.message}
      </span>

      {view.action === null ? null : view.action.kind === 'link' ? (
        <button
          type="button"
          onClick={view.action.run}
          className={cn(
            'shrink-0 rounded-sm text-[0.71875rem] text-fg-muted underline underline-offset-2',
            'decoration-border transition-colors duration-150 hover:text-fg',
            'focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent',
          )}
        >
          {view.action.label}
        </button>
      ) : (
        <Button size="sm" onClick={view.action.run}>
          {view.action.label}
        </Button>
      )}
    </div>
  );
}

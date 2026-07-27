/**
 * Crash / unclean-quit recovery.
 *
 * The main process found a segment that was never closed. Only the user knows what
 * happened in the unaccounted gap, so all three outcomes are offered with the
 * consequence of each spelled out — and the modal has no dismiss, because ignoring
 * it would leave an open segment quietly counting time nobody worked.
 */

import { formatClock, formatCompact, formatDateLong } from '@shared/time';
import type { PendingRecovery, RecoveryChoice } from '@shared/types';

import { Button } from '@renderer/components/Button';
import type { ButtonVariant } from '@renderer/components/Button';
import { Modal } from '@renderer/components/Modal';

export interface RecoveryPromptProps {
  open: boolean;
  prompt: PendingRecovery;
  /** True while a choice is being applied, so it cannot be answered twice. */
  busy?: boolean;
  onResolve: (choice: RecoveryChoice) => void;
}

interface RecoveryOption {
  choice: RecoveryChoice;
  label: string;
  hint: string;
  variant: ButtonVariant;
}

export function RecoveryPrompt({ open, prompt, busy = false, onResolve }: RecoveryPromptProps) {
  const { segment, recoverableMs, gapMs } = prompt;

  const options: readonly RecoveryOption[] = [
    {
      choice: 'close-at-heartbeat',
      label: `Keep ${formatCompact(recoverableMs)}`,
      hint: 'Ends the segment at the last heartbeat and drops the unaccounted time.',
      variant: 'primary',
    },
    {
      choice: 'resume',
      label: 'Resume it',
      hint: 'Leaves the segment open and keeps counting from when it started.',
      variant: 'secondary',
    },
    {
      choice: 'discard',
      label: 'Discard',
      hint: 'Deletes the segment; none of that time is counted.',
      variant: 'ghost',
    },
  ];

  return (
    <Modal open={open} title="Unfinished session">
      <div className="space-y-3.5">
        <p className="leading-snug">
          Dayly closed while a {segment.type} segment was still running. It started at{' '}
          <span className="font-medium tabular-nums text-fg">{formatClock(segment.startedAt)}</span>{' '}
          on {formatDateLong(prompt.date)}.
        </p>

        <dl className="grid grid-cols-2 gap-3 rounded-lg bg-sunken px-3 py-2">
          <div>
            <dt className="text-[0.6875rem] text-fg-faint">Recoverable</dt>
            <dd className="text-sm font-medium tabular-nums text-fg">
              {formatCompact(recoverableMs)}
            </dd>
          </div>
          <div>
            <dt className="text-[0.6875rem] text-fg-faint">Unaccounted</dt>
            <dd className="text-sm font-medium tabular-nums text-fg">{formatCompact(gapMs)}</dd>
          </div>
        </dl>

        <div className="space-y-2.5">
          {options.map((option) => (
            <div key={option.choice}>
              <Button
                variant={option.variant}
                className="w-full"
                disabled={busy}
                onClick={() => onResolve(option.choice)}
              >
                {option.label}
              </Button>
              <p className="mt-1 text-[0.6875rem] leading-snug text-fg-faint">{option.hint}</p>
            </div>
          ))}
        </div>
      </div>
    </Modal>
  );
}

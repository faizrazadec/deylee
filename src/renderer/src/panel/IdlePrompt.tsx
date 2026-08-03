/**
 * Idle detection: the system reported no input for longer than the threshold while a
 * work segment was open. The answer is sent back with the prompt's `id`, never "the
 * segment that is open now", so a prompt answered late cannot trim the wrong stretch.
 */

import { formatClock, formatCompact } from '@shared/time';
import type { IdleChoice, IdlePrompt as IdlePromptPayload } from '@shared/types';

import { Button } from '@renderer/components/Button';
import { Modal } from '@renderer/components/Modal';

export interface IdlePromptProps {
  open: boolean;
  prompt: IdlePromptPayload;
  /** True while a choice is being applied, so it cannot be answered twice. */
  busy?: boolean;
  onResolve: (choice: IdleChoice) => void;
}

export function IdlePrompt({ open, prompt, busy = false, onResolve }: IdlePromptProps) {
  const idleEndedAt = prompt.idleStartedAt + prompt.idleMs;

  return (
    <Modal
      open={open}
      title="Away from your desk?"
      footer={
        <>
          <Button variant="ghost" disabled={busy} onClick={() => onResolve('discard')}>
            Discard
          </Button>
          <Button variant="primary" disabled={busy} onClick={() => onResolve('keep')}>
            Keep
          </Button>
        </>
      }
    >
      <div className="space-y-2">
        <p className="leading-snug">
          You were idle for{' '}
          <span className="font-medium tabular-nums text-fg">{formatCompact(prompt.idleMs)}</span>,
          from <span className="tabular-nums">{formatClock(prompt.idleStartedAt)}</span> to{' '}
          <span className="tabular-nums">{formatClock(idleEndedAt)}</span>.
        </p>
        <p className="text-[0.6875rem] leading-snug text-fg-faint">
          Keep counts that time as work. Discard ends the segment at{' '}
          {formatClock(prompt.idleStartedAt)} and opens a fresh one now, so the idle stretch is
          simply absent from the day.
        </p>
      </div>
    </Modal>
  );
}

/**
 * Sleep / lock gap.
 *
 * The work segment was already closed when the machine went away, so nothing is
 * counting right now. What is still undecided is the gap itself — unrecorded, or a
 * break — and either answer starts work again from this moment.
 */

import { formatClock, formatCompact } from '@shared/time';
import type { WakeChoice, WakePrompt as WakePromptPayload, WakeReason } from '@shared/types';

import { Button } from '@renderer/components/Button';
import { Modal } from '@renderer/components/Modal';

export interface WakePromptProps {
  open: boolean;
  prompt: WakePromptPayload;
  /** True while a choice is being applied, so it cannot be answered twice. */
  busy?: boolean;
  onResolve: (choice: WakeChoice) => void;
}

function describeReason(reason: WakeReason): string {
  return reason === 'suspend' ? 'This computer was asleep' : 'The screen was locked';
}

export function WakePrompt({ open, prompt, busy = false, onResolve }: WakePromptProps) {
  return (
    <Modal
      open={open}
      title="Welcome back"
      footer={
        <>
          <Button variant="secondary" disabled={busy} onClick={() => onResolve('count-as-break')}>
            Count as break
          </Button>
          <Button variant="primary" disabled={busy} onClick={() => onResolve('resume')}>
            Resume work
          </Button>
        </>
      }
    >
      <div className="space-y-2">
        <p className="leading-snug">
          {describeReason(prompt.reason)} for{' '}
          <span className="font-medium tabular-nums text-fg">{formatCompact(prompt.gapMs)}</span>,
          from <span className="tabular-nums">{formatClock(prompt.gapStartedAt)}</span> to{' '}
          <span className="tabular-nums">{formatClock(prompt.gapEndedAt)}</span>. Timing stopped
          the moment it happened.
        </p>
        <p className="text-[0.6875rem] leading-snug text-fg-faint">
          Resume work leaves the gap off the record. Count as break stores it as a break segment.
          Either way, work starts again now.
        </p>
      </div>
    </Modal>
  );
}

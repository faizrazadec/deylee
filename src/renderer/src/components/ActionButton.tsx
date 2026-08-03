import type { TimerState } from '@shared/types';
import { Button } from '@renderer/components/Button';
import type { ButtonVariant } from '@renderer/components/Button';

export interface ActionButtonProps {
  state: TimerState;
  compact?: boolean;
  disabled?: boolean;
  onStart: () => void;
  onPause: () => void;
  onResume: () => void;
}

interface Action {
  label: string;
  variant: ButtonVariant;
  run: () => void;
  paused: boolean;
}

export function ActionButton({
  state,
  compact = false,
  disabled = false,
  onStart,
  onPause,
  onResume,
}: ActionButtonProps) {
  const action = resolveAction(state, onStart, onPause, onResume);
  const icon = action.paused ? <PauseIcon /> : <PlayIcon />;

  if (compact) {
    return (
      <Button
        variant={action.variant}
        size="sm"
        disabled={disabled}
        onClick={action.run}
        aria-label={action.label}
        title={action.label}
        className="size-8 rounded-full p-0"
      >
        {icon}
      </Button>
    );
  }

  return (
    <Button
      variant={action.variant}
      size="lg"
      disabled={disabled}
      onClick={action.run}
      className="w-full gap-2"
    >
      {icon}
      {action.label}
    </Button>
  );
}

/**
 * The one action a given state offers. ENDED still starts — pressing it reopens
 * today with a fresh work segment — but it is labelled so the user knows the day
 * was already finalised.
 */
function resolveAction(
  state: TimerState,
  onStart: () => void,
  onPause: () => void,
  onResume: () => void,
): Action {
  switch (state) {
    case 'RUNNING':
      return { label: 'Pause', variant: 'secondary', run: onPause, paused: true };
    case 'PAUSED':
      return { label: 'Resume', variant: 'primary', run: onResume, paused: false };
    case 'ENDED':
      return { label: 'Start again', variant: 'primary', run: onStart, paused: false };
    case 'IDLE':
      return { label: 'Start', variant: 'primary', run: onStart, paused: false };
  }
}

function PlayIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      <path d="M5.2 3.1v9.8a.7.7 0 0 0 1.07.6l7.3-4.9a.7.7 0 0 0 0-1.2l-7.3-4.9a.7.7 0 0 0-1.07.6Z" />
    </svg>
  );
}

function PauseIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      <rect x="4" y="3" width="3" height="10" rx="1.2" />
      <rect x="9" y="3" width="3" height="10" rx="1.2" />
    </svg>
  );
}

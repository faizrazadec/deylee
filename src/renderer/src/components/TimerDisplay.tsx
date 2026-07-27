import { formatHM, formatHMS } from '@shared/time';
import { cn } from '@renderer/lib/api';

export interface TimerDisplayProps {
  ms: number;
  withSeconds?: boolean;
  /**
   * Render the seconds at a smaller size and one contrast step down, as the panel
   * hero does. The seconds are the fastest-moving, least important digits, so
   * de-emphasising them keeps the eye on the hours without losing the liveness cue.
   */
  splitSeconds?: boolean;
  className?: string;
  secondsClassName?: string;
}

export function TimerDisplay({
  ms,
  withSeconds = false,
  splitSeconds = false,
  className,
  secondsClassName,
}: TimerDisplayProps) {
  // `tabular-nums` is not cosmetic: without it every digit change re-measures the
  // string and the whole timer shifts sideways once a second.
  const base = cn('tabular-nums tracking-tight', className);

  if (!withSeconds) {
    return <span className={base}>{formatHM(ms)}</span>;
  }

  const text = formatHMS(ms);
  if (!splitSeconds) {
    return <span className={base}>{text}</span>;
  }

  // formatHMS is always `H:MM:SS`, so the final colon is the split point.
  const cut = text.lastIndexOf(':');
  return (
    <span className={base}>
      {text.slice(0, cut)}
      <span className={cn('text-[0.5em] tracking-normal', secondsClassName)}>
        {text.slice(cut)}
      </span>
    </span>
  );
}

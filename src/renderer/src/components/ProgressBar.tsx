import { cn } from '@renderer/lib/api';

export interface ProgressBarProps {
  progress: number;
  className?: string;
}

export function ProgressBar({ progress, className }: ProgressBarProps) {
  // `liveTotals` leaves `targetProgress` unclamped so callers can tell "met" from
  // "exceeded"; the bar clamps for width and uses the overflow only as a tint.
  const safe = Number.isFinite(progress) ? progress : 0;
  const clamped = Math.min(1, Math.max(0, safe));
  const met = safe >= 1;

  return (
    <div
      role="progressbar"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(clamped * 100)}
      className={cn('h-1.5 w-full overflow-hidden rounded-full bg-sunken', className)}
    >
      <div
        className={cn(
          'h-full rounded-full transition-[width,background-color] duration-500 ease-out',
          met ? 'bg-work' : 'bg-accent',
        )}
        style={{ width: `${clamped * 100}%` }}
      />
    </div>
  );
}

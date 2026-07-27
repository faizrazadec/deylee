import { useCallback, useEffect, useId, useState } from 'react';
import { cn } from '@renderer/lib/api';

export interface NumberFieldProps {
  value: number;
  onChange: (next: number) => void;
  label: string;
  min?: number;
  max?: number;
  step?: number;
  description?: string;
  suffix?: string;
  disabled?: boolean;
}

export function NumberField({
  value,
  onChange,
  label,
  min,
  max,
  step = 1,
  description,
  suffix,
  disabled = false,
}: NumberFieldProps) {
  const id = useId();
  // The field is committed on blur/Enter, not on every keystroke, so half-typed
  // text like "1" on the way to "15" is never clamped out from under the user.
  const [draft, setDraft] = useState<string>(() => String(value));

  useEffect(() => {
    setDraft(String(value));
  }, [value]);

  const clamp = useCallback(
    (next: number): number => {
      let out = next;
      if (min !== undefined) out = Math.max(min, out);
      if (max !== undefined) out = Math.min(max, out);
      return out;
    },
    [min, max],
  );

  const commitNumber = useCallback(
    (next: number): void => {
      const clamped = clamp(next);
      setDraft(String(clamped));
      if (clamped !== value) onChange(clamped);
    },
    [clamp, onChange, value],
  );

  const commitDraft = useCallback((): void => {
    const parsed = Number(draft.trim());
    // Empty or nonsense input reverts rather than writing a NaN preference.
    if (draft.trim() === '' || !Number.isFinite(parsed)) {
      setDraft(String(value));
      return;
    }
    commitNumber(parsed);
  }, [commitNumber, draft, value]);

  const atMin = min !== undefined && value <= min;
  const atMax = max !== undefined && value >= max;

  const stepperClass =
    'flex size-7 items-center justify-center rounded-md text-fg-muted transition-colors ' +
    'hover:bg-hover hover:text-fg focus-visible:outline-2 focus-visible:outline-offset-2 ' +
    'focus-visible:outline-accent disabled:pointer-events-none disabled:opacity-35';

  return (
    <div className="flex items-start justify-between gap-4 px-2 py-2">
      <div className="min-w-0">
        <label htmlFor={id} className="block text-sm font-medium text-fg">
          {label}
        </label>
        {description === undefined ? null : (
          <p className="mt-0.5 text-xs leading-relaxed text-fg-faint">{description}</p>
        )}
      </div>

      <div
        className={cn(
          'flex shrink-0 items-center gap-1 rounded-lg border border-border bg-raised p-1',
          'transition-colors focus-within:border-accent',
          disabled && 'pointer-events-none opacity-45',
        )}
      >
        <button
          type="button"
          className={stepperClass}
          onClick={() => commitNumber(value - step)}
          disabled={disabled || atMin}
          aria-label={`Decrease ${label}`}
        >
          <MinusIcon />
        </button>

        <input
          id={id}
          type="text"
          inputMode="decimal"
          value={draft}
          disabled={disabled}
          aria-label={label}
          onChange={(event) => setDraft(event.target.value)}
          onBlur={commitDraft}
          onKeyDown={(event) => {
            if (event.key === 'Enter') {
              event.preventDefault();
              commitDraft();
            } else if (event.key === 'Escape') {
              setDraft(String(value));
            }
          }}
          className="w-12 bg-transparent text-center text-sm font-medium tabular-nums text-fg outline-none"
        />

        {suffix === undefined ? null : (
          <span className="pr-1 text-xs text-fg-faint">{suffix}</span>
        )}

        <button
          type="button"
          className={stepperClass}
          onClick={() => commitNumber(value + step)}
          disabled={disabled || atMax}
          aria-label={`Increase ${label}`}
        >
          <PlusIcon />
        </button>
      </div>
    </div>
  );
}

function MinusIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      <rect x="3" y="7.25" width="10" height="1.5" rx="0.75" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden className="size-3.5" fill="currentColor">
      <rect x="3" y="7.25" width="10" height="1.5" rx="0.75" />
      <rect x="7.25" y="3" width="1.5" height="10" rx="0.75" />
    </svg>
  );
}

import { cn } from '@renderer/lib/api';

export interface ToggleProps {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
  description?: string;
  disabled?: boolean;
}

export function Toggle({ checked, onChange, label, description, disabled = false }: ToggleProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={cn(
        'group flex w-full items-start justify-between gap-4 rounded-lg px-2 py-2 text-left',
        'transition-colors duration-150 focus-visible:outline-2 focus-visible:outline-offset-2',
        'focus-visible:outline-accent',
        disabled ? 'cursor-not-allowed opacity-45' : 'hover:bg-hover',
      )}
    >
      <span className="min-w-0">
        <span className="block text-sm font-medium text-fg">{label}</span>
        {description === undefined ? null : (
          <span className="mt-0.5 block text-xs leading-relaxed text-fg-faint">{description}</span>
        )}
      </span>

      <span
        aria-hidden
        className={cn(
          'relative mt-0.5 h-5 w-9 shrink-0 rounded-full border border-transparent',
          'transition-colors duration-150',
          // The off track is a tint of the muted ink rather than a surface colour,
          // so the white knob keeps its contrast in both themes.
          checked ? 'bg-accent' : 'bg-fg-faint/35',
        )}
      >
        <span
          className={cn(
            'absolute top-[3px] left-[3px] size-3.5 rounded-full bg-white shadow-sm',
            'transition-transform duration-150 ease-out',
            checked && 'translate-x-4',
          )}
        />
      </span>
    </button>
  );
}

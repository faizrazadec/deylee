import type { ButtonHTMLAttributes } from 'react';
import { cn } from '@renderer/lib/api';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'danger';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: 'sm' | 'md' | 'lg';
}

const BASE =
  'inline-flex shrink-0 items-center justify-center gap-1.5 rounded-lg font-medium ' +
  'whitespace-nowrap transition-colors duration-150 focus-visible:outline-2 ' +
  'focus-visible:outline-offset-2 focus-visible:outline-accent ' +
  'disabled:pointer-events-none disabled:opacity-45';

const VARIANTS: Record<ButtonVariant, string> = {
  primary: 'bg-accent text-accent-fg shadow-sm shadow-accent/25 hover:bg-accent-hover',
  secondary: 'border border-border bg-raised text-fg hover:bg-hover',
  ghost: 'text-fg-muted hover:bg-hover hover:text-fg',
  danger: 'border border-danger/25 bg-danger-soft text-danger hover:border-danger hover:bg-danger hover:text-white',
};

const SIZES: Record<NonNullable<ButtonProps['size']>, string> = {
  sm: 'h-7 px-2.5 text-xs',
  md: 'h-9 px-3.5 text-sm',
  lg: 'h-11 px-5 text-[0.9375rem]',
};

export function Button({
  variant = 'secondary',
  size = 'md',
  className,
  // Defaulting to `button` keeps a button inside a form from submitting it.
  type = 'button',
  ...rest
}: ButtonProps) {
  return (
    <button
      type={type}
      className={cn(BASE, VARIANTS[variant], SIZES[size], className)}
      {...rest}
    />
  );
}

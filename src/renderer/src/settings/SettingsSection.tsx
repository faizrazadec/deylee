import type { ReactNode } from 'react';

export interface SettingsSectionProps {
  title: string;
  description?: string;
  children: ReactNode;
}

/**
 * One titled group of preferences.
 *
 * Rows bring their own padding — `Toggle` and `NumberField` are built that way — so
 * this only supplies the frame and the hairlines between them, and any row written
 * locally must match that `px-2 py-2` rhythm to sit flush with them.
 */
export function SettingsSection({ title, description, children }: SettingsSectionProps) {
  return (
    <section>
      <h2 className="px-1 text-[11px] font-semibold tracking-wider text-fg-faint uppercase">
        {title}
      </h2>
      {description === undefined ? null : (
        <p className="mt-1 px-1 text-xs leading-relaxed text-fg-muted">{description}</p>
      )}
      <div className="mt-2 divide-y divide-border rounded-xl border border-border bg-raised p-1.5">
        {children}
      </div>
    </section>
  );
}

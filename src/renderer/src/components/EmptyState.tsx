export interface EmptyStateProps {
  title: string;
  description?: string;
}

export function EmptyState({ title, description }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-center justify-center gap-1.5 rounded-window border border-dashed border-border px-6 py-10 text-center">
      <p className="text-sm font-medium text-fg-muted">{title}</p>
      {description === undefined ? null : (
        <p className="max-w-[32ch] text-xs leading-relaxed text-fg-faint">{description}</p>
      )}
    </div>
  );
}

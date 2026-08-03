import { useEffect, useId } from 'react';
import type { MouseEvent, ReactNode } from 'react';

export interface ModalProps {
  open: boolean;
  title: string;
  children: ReactNode;
  footer?: ReactNode;
  onClose?: () => void;
}

export function Modal({ open, title, children, footer, onClose }: ModalProps) {
  const titleId = useId();

  useEffect(() => {
    // A modal with no `onClose` is a decision the user must actually make — the
    // recovery prompt, for one — so Escape is only wired when dismissal is allowed.
    if (!open || onClose === undefined) return undefined;
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [open, onClose]);

  if (!open) return null;

  const onBackdropMouseDown = (event: MouseEvent<HTMLDivElement>): void => {
    // mousedown, not click, and only when it starts on the backdrop itself: a drag
    // that begins inside the dialog and ends outside must not dismiss it.
    if (onClose !== undefined && event.target === event.currentTarget) onClose();
  };

  return (
    <div
      onMouseDown={onBackdropMouseDown}
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/45 p-5 backdrop-blur-[2px]"
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className="w-full max-w-sm overflow-hidden rounded-window border border-border bg-raised shadow-panel"
      >
        <header className="border-b border-border px-4 py-3">
          <h2 id={titleId} className="text-sm font-semibold text-fg">
            {title}
          </h2>
        </header>

        <div className="px-4 py-4 text-sm leading-relaxed text-fg-muted">{children}</div>

        {footer === undefined ? null : (
          <footer className="flex flex-wrap items-center justify-end gap-2 border-t border-border bg-sunken px-4 py-3">
            {footer}
          </footer>
        )}
      </div>
    </div>
  );
}

import type { HTMLAttributes, ReactNode } from 'react';

export interface SheetProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title?: string;
  /** Action row at the bottom, usually a primary Button. */
  footer?: ReactNode;
  /** Draws the scrim behind the sheet, anchored to the bottom, in its own box. */
  scrim?: boolean;
  children?: ReactNode;
}

/** The open bottom sheet panel, rendered statically (not a portal), as used on a phone: full width, drag handle, raised surface. Wider windows get a Dialog instead. */
export function Sheet({ title, footer, scrim = false, className, children, ...rest }: SheetProps) {
  const panel = (
    <div className={['sm-sheet', className].filter(Boolean).join(' ')} role="dialog" aria-label={title} {...rest}>
      <span className="sm-sheet__handle" aria-hidden />
      {title && <h2 className="sm-sheet__title">{title}</h2>}
      <div className="sm-sheet__body">{children}</div>
      {footer && <div className="sm-sheet__footer">{footer}</div>}
    </div>
  );
  return scrim ? <div className="sm-sheet-scrim">{panel}</div> : panel;
}

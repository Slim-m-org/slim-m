import type { HTMLAttributes, ReactNode } from 'react';

export interface DialogProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title?: string;
  /** Action row at the bottom, usually a secondary Cancel and a primary Button. */
  actions?: ReactNode;
  /** Draws the scrim behind the panel in its own box, to mock the open state in context. */
  scrim?: boolean;
  /** Panel max width in px; defaults to 460. */
  maxWidth?: number;
  children?: ReactNode;
}

/** The open in-window dialog panel, rendered statically (not a portal): raised surface, hairline, 10px radius, 16px top inset. Set `scrim` to show it over the dimmed window. */
export function Dialog({ title, actions, scrim = false, maxWidth = 460, className, style, children, ...rest }: DialogProps) {
  const panel = (
    <div
      className={['sm-dialog', className].filter(Boolean).join(' ')}
      role="dialog"
      aria-modal={scrim || undefined}
      aria-label={title}
      style={{ maxWidth, ...style }}
      {...rest}
    >
      {title && <h2 className="sm-dialog__title">{title}</h2>}
      <div className="sm-dialog__body">{children}</div>
      {actions && <div className="sm-dialog__actions">{actions}</div>}
    </div>
  );
  return scrim ? <div className="sm-dialog-scrim">{panel}</div> : panel;
}

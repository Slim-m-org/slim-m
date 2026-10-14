import type { HTMLAttributes } from 'react';

export type UnreadDividerProps = Omit<HTMLAttributes<HTMLDivElement>, 'children'>;

/** The "NEW" marker above the first unread message: a half-strength accent rule with the label at the right edge. One per channel at most. Gutter is 20px at 600px and wider, 10px below. */
export function UnreadDivider({ className, ...rest }: UnreadDividerProps) {
  return (
    <div className={['sm-unread-divider', className].filter(Boolean).join(' ')} role="separator" aria-label="New messages" {...rest}>
      <span className="sm-unread-divider__rule" />
      <span className="sm-unread-divider__label">NEW</span>
    </div>
  );
}

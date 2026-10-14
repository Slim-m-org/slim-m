import type { HTMLAttributes } from 'react';
import { Icon, type IconName } from './Icon';

export type ToastSeverity = 'success' | 'info' | 'warning';

export interface ToastProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  message: string;
  /** success is a confirmation, info is neutral, warning is a non-failure caution. There is no error severity: failures use ErrorState. */
  severity?: ToastSeverity;
  /** When given, draws a dismiss glyph and makes the whole toast clickable. */
  onDismiss?: () => void;
}

const icons: Record<ToastSeverity, IconName> = { success: 'check', info: 'info', warning: 'warning' };

/** A transient confirmation ("Copied", "Saved"), outlined in its severity tone over the raised surface and never filled. Not for failures. */
export function Toast({ message, severity = 'info', onDismiss, className, onClick, ...rest }: ToastProps) {
  const classes = ['sm-toast', `sm-toast--${severity}`, onDismiss && 'sm-toast--dismissible', className].filter(Boolean).join(' ');
  return (
    <div className={classes} role="status" aria-live="polite" onClick={onDismiss ?? onClick} {...rest}>
      <span className="sm-toast__icon">
        <Icon name={icons[severity]} size={16} />
      </span>
      <span className="sm-toast__message">{message}</span>
      {onDismiss && <Icon name="dismiss" size={16} className="sm-toast__dismiss" />}
    </div>
  );
}

import type { HTMLAttributes } from 'react';
import { Button } from './Button';
import { Icon } from './Icon';

export interface ErrorStateProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** What happened, in plain words. Never a raw exception. */
  message: string;
  /** Technical line for the server operator (status code, limit, host), set in mono. */
  detail?: string;
  /** Shows the Retry button when given. */
  onRetry?: () => void;
  retryLabel?: string;
  /** Shows the Dismiss button when given. */
  onDismiss?: () => void;
  dismissLabel?: string;
}

/** The persistent record of a failed action, shown at the point of the action and kept until something changes it; replaces snackbars. Outlined in the danger border, never filled. Pass `onRetry` and/or `onDismiss` (even a no-op in a mock) to show the buttons. */
export function ErrorState({ message, detail, onRetry, retryLabel = 'Retry', onDismiss, dismissLabel = 'Dismiss', className, ...rest }: ErrorStateProps) {
  return (
    <div className={['sm-errorstate', className].filter(Boolean).join(' ')} role="alert" {...rest}>
      <div className="sm-errorstate__head">
        <span className="sm-errorstate__icon">
          <Icon name="failed" size={16} />
        </span>
        <span className="sm-errorstate__message">{message}</span>
      </div>
      {detail && <div className="sm-errorstate__detail">{detail}</div>}
      {(onRetry || onDismiss) && (
        <div className="sm-errorstate__actions">
          {onRetry && <Button label={retryLabel} size="sm" variant="danger" onClick={onRetry} />}
          {onDismiss && <Button label={dismissLabel} size="sm" onClick={onDismiss} />}
        </div>
      )}
    </div>
  );
}

import type { HTMLAttributes, ReactNode } from 'react';
import { Button } from './Button';
import { Icon, type IconName } from './Icon';
import { IconButton } from './IconButton';

export type StatusBannerTone = 'transient' | 'failure' | 'info';

export interface StatusBannerProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** transient is amber and clears itself (reconnecting, offline); failure is red and attaches to what failed; info is neutral (an update is ready). */
  tone?: StatusBannerTone;
  /** One plain sentence. Overrides nothing else; put detail in `children`. */
  message: string;
  /** Extra line under the message, such as a timeout reason. */
  children?: ReactNode;
  /** Overrides the per-tone glyph: retry, failed, info. */
  icon?: IconName;
  /** Label for the single action (Retry, Restart). Renders when `onAction` is given. */
  actionLabel?: string;
  onAction?: () => void;
  onDismiss?: () => void;
}

const defaultIcon: Record<StatusBannerTone, IconName> = { transient: 'retry', failure: 'failed', info: 'info' };

/** A full-width status strip that sits in the layout flow above the content it concerns and pushes it down, never overlaying it. Amber for transient trouble, red for a failure, neutral for information; errors never go in a toast. Stack it as the first child of a column, or use AppShell's `banner` slot. On compact it is at least 44px tall. */
export function StatusBanner({ tone = 'transient', message, children, icon, actionLabel = 'Retry', onAction, onDismiss, className, ...rest }: StatusBannerProps) {
  return (
    <div
      className={['sm-statusbanner', `sm-statusbanner--${tone}`, className].filter(Boolean).join(' ')}
      role={tone === 'failure' ? 'alert' : 'status'}
      {...rest}
    >
      <span className="sm-statusbanner__icon">
        <Icon name={icon ?? defaultIcon[tone]} size={16} />
      </span>
      <div className="sm-statusbanner__body">
        <div className="sm-statusbanner__message">{message}</div>
        {children && <div className="sm-statusbanner__detail">{children}</div>}
      </div>
      {onAction && <Button size="sm" variant="secondary" label={actionLabel} onClick={onAction} />}
      {onDismiss && <IconButton icon="dismiss" label="Dismiss" size="sm" iconSize={16} onClick={onDismiss} />}
    </div>
  );
}

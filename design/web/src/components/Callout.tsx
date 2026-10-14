import type { HTMLAttributes, ReactNode } from 'react';
import { Icon, type IconName } from './Icon';

export type CalloutTone = 'warn' | 'info' | 'accent';

export interface CalloutProps extends HTMLAttributes<HTMLDivElement> {
  /** warn is a caution or "why this is unavailable"; info is neutral background; accent is a positive highlight. There is no danger tone. */
  tone?: CalloutTone;
  /** Overrides the per-tone default: warning, info, highlight. */
  icon?: IconName;
  children?: ReactNode;
}

const defaultIcon: Record<CalloutTone, IconName> = { warn: 'warning', info: 'info', accent: 'highlight' };
const toneLabel: Record<CalloutTone, string> = { warn: 'Warning', info: 'Info', accent: 'Highlight' };

/** A tone-coded inline banner for something the surrounding content cannot say itself, such as an expiring invite or why a control is unavailable. */
export function Callout({ tone = 'warn', icon, className, children, ...rest }: CalloutProps) {
  const classes = ['sm-callout', `sm-callout--${tone}`, className].filter(Boolean).join(' ');
  return (
    <div className={classes} role="note" aria-label={toneLabel[tone]} {...rest}>
      <span className="sm-callout__icon">
        <Icon name={icon ?? defaultIcon[tone]} size={16} />
      </span>
      <div className="sm-callout__body">{children}</div>
    </div>
  );
}

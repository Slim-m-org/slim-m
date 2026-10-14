import type { HTMLAttributes } from 'react';
import { Icon, type IconName } from './Icon';

export type BadgeVariant = 'role' | 'tag' | 'warn';

export interface BadgeProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'children'> {
  label: string;
  /** role is accent-outlined and never per-role coloured; tag is neutral; warn is amber for stale-ness. */
  variant: BadgeVariant;
  /** A small leading glyph, in any variant. */
  icon?: IconName;
}

/** A small outlined, uppercase label chip for a member role, a bot tag or a warning. Never filled. */
export function Badge({ label, variant, icon, className, ...rest }: BadgeProps) {
  return (
    <span className={['sm-badge', `sm-badge--${variant}`, className].filter(Boolean).join(' ')} aria-label={label} {...rest}>
      {icon && <Icon name={icon} size={16} />}
      <span className="sm-badge__label" aria-hidden>
        {label}
      </span>
    </span>
  );
}

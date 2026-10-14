import type { ButtonHTMLAttributes } from 'react';
import { Icon, type IconName } from './Icon';

export type IconButtonVariant = 'ghost' | 'danger' | 'dangerGhost';
export type IconButtonSize = 'sm' | 'md' | 'touch';

export interface IconButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
  icon: IconName;
  /** Accessible name. Required: an icon-only control has nothing else to say it. */
  label: string;
  /** danger states the consequence at rest; dangerGhost withholds it until hover. */
  variant?: IconButtonVariant;
  /** sm 26px, md 28px, touch 38px visual square. */
  size?: IconButtonSize;
  /** Persistent accent-tinted state (toggled on, filter applied). Not keyboard focus. */
  active?: boolean;
  /** Grow the hit box to 44px instead of 30px, without growing the glyph. */
  touch?: boolean;
  /** Glyph size, 20 by default. */
  iconSize?: 16 | 20 | 24;
  /** Drop this button's own hover fill when an enclosing row already tints on hover. */
  suppressOwnHoverFill?: boolean;
}

/** A square icon-only button for header actions, toolbars and message-row hover actions. Corners are 6px (10px at touch size), not a circle. */
export function IconButton({
  icon,
  label,
  variant = 'ghost',
  size = 'md',
  active = false,
  touch = false,
  iconSize = 20,
  suppressOwnHoverFill = false,
  className,
  title,
  ...rest
}: IconButtonProps) {
  const classes = [
    'sm-icon-button',
    `sm-icon-button--${variant}`,
    `sm-icon-button--${size}`,
    touch && 'sm-icon-button--touch-target',
    active && 'sm-icon-button--active',
    suppressOwnHoverFill && 'sm-icon-button--no-hover-fill',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <button type="button" className={classes} aria-label={label} aria-pressed={active || undefined} title={title} {...rest}>
      <span className="sm-icon-button__visual">
        <Icon name={icon} size={iconSize} />
      </span>
    </button>
  );
}

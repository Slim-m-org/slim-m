import type { ButtonHTMLAttributes } from 'react';
import { Icon, type IconName } from './Icon';

export type ButtonVariant = 'primary' | 'secondary' | 'ghost' | 'soft' | 'danger';
export type ButtonSize = 'sm' | 'md' | 'lg';

export interface ButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
  label: string;
  /** primary is the one accent action on a surface; secondary is the default; soft is an accent-tinted toggle-like action; danger is destructive. */
  variant?: ButtonVariant;
  /** sm 28px, md 34px, lg 40px tall. */
  size?: ButtonSize;
  icon?: IconName;
  /** Stretch to the container's width. */
  full?: boolean;
  /** Shows a spinner in place of the label and blocks presses. */
  busy?: boolean;
}

/** A labelled button. Hairline-bordered, 6px radius, no shadow; press scales to 0.98, disabled fades to 45%. */
export function Button({
  label,
  variant = 'secondary',
  size = 'md',
  icon,
  full = false,
  busy = false,
  disabled,
  className,
  ...rest
}: ButtonProps) {
  const classes = ['sm-button', `sm-button--${variant}`, `sm-button--${size}`, full && 'sm-button--full', busy && 'sm-button--busy', className]
    .filter(Boolean)
    .join(' ');
  return (
    <button type="button" className={classes} disabled={disabled || busy} aria-busy={busy || undefined} {...rest}>
      {busy ? (
        <span className="sm-button__spinner" aria-hidden />
      ) : (
        <>
          {icon && <Icon name={icon} size={16} />}
          <span className="sm-button__label">{label}</span>
        </>
      )}
    </button>
  );
}

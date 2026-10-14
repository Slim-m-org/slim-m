import type { ButtonHTMLAttributes } from 'react';

export interface ToggleProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'onChange' | 'value'> {
  value: boolean;
  onChange?: (value: boolean) => void;
  /** On and deliberately not changeable, for a cue that must not be switched off. Dims to 60% instead of using disabled colours. */
  locked?: boolean;
}

/** An on/off switch, 40x22. State reads from thumb position and track fill together, never colour alone; pair it with a text label. */
export function Toggle({ value, onChange, locked = false, className, onClick, ...rest }: ToggleProps) {
  const interactive = !locked && !!onChange;
  const classes = ['sm-toggle', value && 'sm-toggle--on', locked && 'sm-toggle--locked', !interactive && 'sm-toggle--static', className]
    .filter(Boolean)
    .join(' ');
  return (
    <button
      type="button"
      role="switch"
      aria-checked={value}
      aria-disabled={locked || undefined}
      className={classes}
      onClick={(event) => {
        onClick?.(event);
        if (interactive) onChange(!value);
      }}
      {...rest}
    >
      <span className="sm-toggle__thumb" aria-hidden />
    </button>
  );
}

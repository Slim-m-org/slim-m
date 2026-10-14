import type { HTMLAttributes } from 'react';
import { Toggle } from './Toggle';

export interface SettingsToggleRowProps extends Omit<HTMLAttributes<HTMLDivElement>, 'onChange'> {
  label: string;
  /** A second line qualifying a switch whose effect is not obvious from its name. */
  description?: string;
  value: boolean;
  onChange?: (value: boolean) => void;
  /** The switch's own accessible name, the setting rather than the whole sentence. Falls back to the label. */
  'aria-label'?: string;
}

/** One "setting you turn on or off": a label and optional description on the left, a Toggle on the right. The text wraps rather than truncates, so a full sentence survives a phone width. */
export function SettingsToggleRow({ label, description, value, onChange, className, 'aria-label': ariaLabel, ...rest }: SettingsToggleRowProps) {
  return (
    <div className={['sm-settings-toggle-row', className].filter(Boolean).join(' ')} {...rest}>
      <div className="sm-settings-toggle-row__text">
        <span className="sm-settings-toggle-row__label">{label}</span>
        {description && <span className="sm-settings-toggle-row__description">{description}</span>}
      </div>
      <Toggle value={value} onChange={onChange} aria-label={ariaLabel ?? label} />
    </div>
  );
}

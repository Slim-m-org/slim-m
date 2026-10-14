import type { ButtonHTMLAttributes } from 'react';
import { Icon } from './Icon';

export interface SettingsSelectRowProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'value'> {
  label: string;
  /** The label of the current choice. Omit for "not known yet". */
  value?: string;
  /** Shown when value is omitted; must never equal a real choice's label. */
  unknownLabel?: string;
}

/** A settings row for a choice among more than about three options: the label on the left, the current value and a chevron on the right. Click opens the picker (a dropdown down the chevron on desktop widths, a sheet on a phone); here it is just an onClick. */
export function SettingsSelectRow({ label, value, unknownLabel = 'Unknown', className, ...rest }: SettingsSelectRowProps) {
  const current = value ?? unknownLabel;
  return (
    <button
      type="button"
      className={['sm-settings-select-row', className].filter(Boolean).join(' ')}
      aria-label={`${label}, currently ${current}`}
      {...rest}
    >
      <span className="sm-settings-select-row__label">{label}</span>
      <span className="sm-settings-select-row__value">{current}</span>
      <span className="sm-settings-select-row__chevron sm-settings-select-row__chevron--down">
        <Icon name="chevronDown" size={16} />
      </span>
      <span className="sm-settings-select-row__chevron sm-settings-select-row__chevron--right">
        <Icon name="chevronRight" size={16} />
      </span>
    </button>
  );
}

import type { HTMLAttributes } from 'react';
import { Icon, type IconName } from './Icon';

export interface SettingsNoticeProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  message: string;
  /** A smaller second line under the message. */
  detail?: string;
  /** Defaults to info. */
  icon?: IconName;
}

/** A centred full-pane message for a settings pane that has nothing to show as a form, such as "Only admins can see this" or a failed load. Not for an empty list inside a card: use SettingsEmpty. */
export function SettingsNotice({ message, detail, icon = 'info', className, ...rest }: SettingsNoticeProps) {
  return (
    <div className={['sm-settings-notice', className].filter(Boolean).join(' ')} {...rest}>
      <Icon name={icon} size={24} className="sm-settings-notice__icon" />
      <p className="sm-settings-notice__message">{message}</p>
      {detail && <p className="sm-settings-notice__detail">{detail}</p>}
    </div>
  );
}

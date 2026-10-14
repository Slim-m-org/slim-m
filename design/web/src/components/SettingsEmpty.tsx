import type { HTMLAttributes } from 'react';
import { SettingsSectionCard } from './SettingsSectionCard';

export interface SettingsEmptyProps extends Omit<HTMLAttributes<HTMLElement>, 'children'> {
  /** One plain sentence saying what is missing, such as "No invites yet." */
  message: string;
}

/** The empty state of a settings list: a section card holding one secondary-ink line. Use it where a roles, bots or invites list has no rows; keep the sentence short and do not add an action. */
export function SettingsEmpty({ message, className, ...rest }: SettingsEmptyProps) {
  return (
    <SettingsSectionCard className={['sm-settings-empty', className].filter(Boolean).join(' ')} {...rest}>
      <p className="sm-settings-empty__line">{message}</p>
    </SettingsSectionCard>
  );
}

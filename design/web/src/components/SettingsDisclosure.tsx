import { useState, type HTMLAttributes, type ReactNode } from 'react';
import { Icon } from './Icon';

export interface SettingsDisclosureProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  title: string;
  /** What is inside, shown at the end of the closed row, such as "3 overrides". */
  summary: string;
  /** Start open; the Flutter widget starts closed. */
  defaultExpanded?: boolean;
  children?: ReactNode;
}

/** A collapsed row inside a settings card that expands to reveal advanced or rarely changed rows. The summary tells the reader what is hidden without opening it. */
export function SettingsDisclosure({ title, summary, defaultExpanded = false, className, children, ...rest }: SettingsDisclosureProps) {
  const [open, setOpen] = useState(defaultExpanded);
  return (
    <div className={['sm-settings-disclosure', className].filter(Boolean).join(' ')} {...rest}>
      <button type="button" className="sm-settings-disclosure__head" aria-expanded={open} aria-label={`${title}, ${summary}, ${open ? 'expanded' : 'collapsed'}`} onClick={() => setOpen(!open)}>
        <Icon name={open ? 'chevronDown' : 'chevronRight'} size={16} className="sm-settings-disclosure__chevron" />
        <span className="sm-settings-disclosure__title">{title}</span>
        <span className="sm-settings-disclosure__summary">{summary}</span>
      </button>
      {open && children}
    </div>
  );
}

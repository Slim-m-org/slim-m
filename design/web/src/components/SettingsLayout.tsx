import type { HTMLAttributes, ReactNode } from 'react';
import { Icon, type IconName } from './Icon';
import { IconButton } from './IconButton';
import { ListRow } from './ListRow';

export interface SettingsNavItem {
  id: string;
  label: string;
  icon?: IconName;
  /** Short caption at the end of the row, such as a count. */
  badge?: string;
}

export interface SettingsNavGroup {
  /** Uppercase mono header with a top hairline; omit for an unlabelled first group. */
  label?: string;
  items: SettingsNavItem[];
}

export interface SettingsLayoutProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  /** Screen title, such as "Settings"; also the app bar of the nav list. */
  title: string;
  groups: SettingsNavGroup[];
  /** The selected section id. Wide windows fall back to the first section so the pane is never empty. */
  activePane?: string;
  /** Compact only: show the selected pane as its own screen with a back button. Wide ignores it. */
  showPane?: boolean;
  /** Pinned under the nav list, such as a sign-out button. */
  footer?: ReactNode;
  /** Draws the ~860x720 floating panel chrome that wide windows show settings in. */
  floating?: boolean;
  /** The selected pane's content. */
  children?: ReactNode;
}

/** Settings and admin as one screen: a 240px section nav beside the open pane at 800px and wider, and below that the nav as a full screen with each pane drilled into as its own screen. Content width decides it, never the platform. */
export function SettingsLayout({ title, groups, activePane, showPane = false, footer, floating = false, className, children, ...rest }: SettingsLayoutProps) {
  const all = groups.flatMap((g) => g.items);
  const selected = all.find((i) => i.id === activePane) ?? (showPane ? undefined : all[0]);
  const wideSelected = all.find((i) => i.id === activePane) ?? all[0];
  const paneScreen = showPane && selected != null;
  const classes = ['sm-settings-layout', paneScreen && 'sm-settings-layout--pane', floating && 'sm-settings-layout--floating', className].filter(Boolean).join(' ');
  return (
    <div className={classes} {...rest}>
      <header className="sm-settings-layout__bar sm-settings-layout__bar--root">
        <IconButton icon="back" label={`Back from ${title.toLowerCase()}`} />
        <h2 className="sm-settings-layout__bar-title">{title}</h2>
      </header>
      {paneScreen && (
        <header className="sm-settings-layout__bar sm-settings-layout__bar--pane">
          <IconButton icon="back" label={`Back to ${title.toLowerCase()}`} />
          <h2 className="sm-settings-layout__bar-title">{selected.label}</h2>
        </header>
      )}
      <div className="sm-settings-layout__body">
        <nav className="sm-settings-layout__nav" aria-label={title}>
          <div className="sm-settings-layout__nav-list">
            {groups.map((group, gi) => (
              <div key={group.label ?? gi} className="sm-settings-layout__group">
                {group.label ? <div className="sm-settings-layout__group-label">{group.label}</div> : <div className="sm-settings-layout__group-gap" />}
                {group.items.map((item) => (
                  <ListRow
                    key={item.id}
                    label={item.label}
                    leading={item.icon && <Icon name={item.icon} size={16} />}
                    meta={item.badge}
                    selected={item.id === wideSelected?.id}
                    trailing={<Icon name="chevronRight" size={16} className="sm-settings-layout__chevron" />}
                    onClick={() => undefined}
                  />
                ))}
              </div>
            ))}
          </div>
          {footer && <div className="sm-settings-layout__footer">{footer}</div>}
        </nav>
        <main className="sm-settings-layout__pane">
          <div className="sm-settings-layout__pane-inner">
            {wideSelected && <h2 className="sm-settings-layout__heading">{wideSelected.label}</h2>}
            {children}
          </div>
        </main>
      </div>
    </div>
  );
}

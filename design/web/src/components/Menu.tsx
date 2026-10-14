import type { HTMLAttributes, ReactNode } from 'react';
import { Icon, type IconName } from './Icon';

export interface MenuProps extends HTMLAttributes<HTMLDivElement> {
  /** Width in px; defaults to 250. */
  width?: number;
  /** Adds the menu shadow; turn off for a menu embedded inline. */
  floating?: boolean;
  children?: ReactNode;
}

/** The floating menu panel: raised surface, strong 1px edge, 10px radius, the menu shadow. Holds MenuItem, MenuLabel, MenuFootnote and MenuDivider. Context menus, dropdowns and long-press sheets share it. */
export function Menu({ width = 250, floating = true, className, style, children, ...rest }: MenuProps) {
  const classes = ['sm-menu', floating && 'sm-menu--floating', className].filter(Boolean).join(' ');
  return (
    <div className={classes} role="menu" style={{ width, ...style }} {...rest}>
      {children}
    </div>
  );
}

/** An uppercase micro section label inside a Menu. */
export function MenuLabel({ children }: { children: ReactNode }) {
  return <div className="sm-menu__label">{children}</div>;
}

/** A sentence-case caveat under a menu's choices. */
export function MenuFootnote({ children }: { children: ReactNode }) {
  return <div className="sm-menu__footnote">{children}</div>;
}

/** A hairline between groups of items. */
export function MenuDivider() {
  return <div className="sm-menu__divider" role="separator" />;
}

export type MenuItemTone = 'normal' | 'warn' | 'danger';

export interface MenuItemProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  label: string;
  icon?: IconName;
  /** Content at the end, such as a keyboard shortcut hint. Takes the slot a selected check would use. */
  trailing?: ReactNode;
  /** Adds a trailing chevron for an item that opens a submenu. */
  submenu?: boolean;
  /** Current-value fill (accent-soft, or warn-soft for the warn tone) and a trailing check. */
  selected?: boolean;
  /** danger is destructive; warn is a caution. */
  tone?: MenuItemTone;
  /** 48px row with body text instead of 34px, for long-press sheets. */
  touch?: boolean;
}

/** One row in a Menu: optional icon, label, trailing content, chevron for submenus. Normal icons are dimmed to secondary ink; warn and danger tint icon and label together. */
export function MenuItem({ label, icon, trailing, submenu = false, selected = false, tone = 'normal', touch = false, className, onClick, ...rest }: MenuItemProps) {
  const classes = ['sm-menuitem', `sm-menuitem--${tone}`, touch && 'sm-menuitem--touch', selected && 'sm-menuitem--selected', className]
    .filter(Boolean)
    .join(' ');
  const end = trailing ?? (selected ? <Icon name="check" size={16} className="sm-menuitem__check" /> : null);
  return (
    <div
      className={classes}
      role="menuitem"
      tabIndex={0}
      onClick={onClick}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          e.currentTarget.click();
        }
      }}
      {...rest}
    >
      {icon && <Icon name={icon} size={16} className="sm-menuitem__icon" />}
      <span className="sm-menuitem__label">{label}</span>
      {(end || submenu) && (
        <span className="sm-menuitem__end">
          {end}
          {submenu && <Icon name="chevronRight" size={16} className="sm-menuitem__chevron" />}
        </span>
      )}
    </div>
  );
}

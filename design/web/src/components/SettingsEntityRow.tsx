import type { HTMLAttributes, ReactNode } from 'react';

export interface SettingsEntityDetailProps {
  children: ReactNode;
  /** warn and danger tint the line; default is secondary ink. */
  tone?: 'warn' | 'danger';
  /** Let a long detail wrap instead of truncating. */
  wrap?: boolean;
}

/** One caption line under an entity row's headline, such as "Created by Mara - 3 uses left". */
export function SettingsEntityDetail({ children, tone, wrap = false }: SettingsEntityDetailProps) {
  return <span className={['sm-entity-row__detail', tone && `sm-entity-row__detail--${tone}`, wrap && 'sm-entity-row__detail--wrap'].filter(Boolean).join(' ')}>{children}</span>;
}

export interface SettingsEntityRowProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  headline: string;
  /** Next to the headline, such as a Badge. */
  badge?: ReactNode;
  /** Before the headline, such as an Avatar or an icon. */
  leading?: ReactNode;
  /** Caption lines under the headline; use SettingsEntityDetail. */
  details?: ReactNode[];
  /** Trailing IconButtons. A null slot keeps the column aligned with rows that have the action. */
  actions?: (ReactNode | null)[];
  /** Fills the row with a sunken hover state and makes it a button. */
  onPress?: () => void;
  /** Persistent inline failure under the row. */
  error?: string;
  /** Tighter 4px vertical padding. */
  dense?: boolean;
}

/** One row of a settings list (a role, a bot, an invite, a member): headline with an optional badge, caption details underneath, icon actions at the end. Put several inside one SettingsSectionCard. */
export function SettingsEntityRow({ headline, badge, leading, details = [], actions = [], onPress, error, dense = false, className, ...rest }: SettingsEntityRowProps) {
  const classes = ['sm-entity-row', dense && 'sm-entity-row--dense', onPress && 'sm-entity-row--interactive', className].filter(Boolean).join(' ');
  return (
    <div className={classes} {...rest}>
      <div
        className="sm-entity-row__main"
        role={onPress ? 'button' : undefined}
        tabIndex={onPress ? 0 : undefined}
        aria-label={onPress ? headline : undefined}
        onClick={onPress}
        onKeyDown={(e) => {
          if (onPress && (e.key === 'Enter' || e.key === ' ')) {
            e.preventDefault();
            onPress();
          }
        }}
      >
        {leading && <span className="sm-entity-row__leading">{leading}</span>}
        <div className="sm-entity-row__text">
          <div className="sm-entity-row__title">
            <span className="sm-entity-row__headline">{headline}</span>
            {badge}
          </div>
          {details.map((d, i) => (
            <div key={i}>{d}</div>
          ))}
        </div>
        {actions.length > 0 && (
          <div className="sm-entity-row__actions">
            {actions.map((a, i) => (a ?? <span key={i} className="sm-entity-row__slot" />))}
          </div>
        )}
      </div>
      {error && (
        <div className="sm-entity-row__error" role="alert">
          {error}
        </div>
      )}
    </div>
  );
}

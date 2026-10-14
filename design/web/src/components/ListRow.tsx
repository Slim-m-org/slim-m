import type { HTMLAttributes, ReactNode } from 'react';
import { Icon, type IconName } from './Icon';

export interface ListRowProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  label: string;
  /** Leading slot: an icon, avatar or status dot. Dimmed to 62% when muted. */
  leading?: ReactNode;
  /** Second line under the label. */
  subtitle?: string;
  /** Small icon before the subtitle. */
  subtitleIcon?: IconName;
  /** Short caption value against the trailing edge, capped at half the row. */
  meta?: string;
  /** Replaces the automatic unread/mention dot. */
  trailing?: ReactNode;
  /** Always shown after trailing, such as a hover action. */
  trailingExtra?: ReactNode;
  /** Accent-soft fill plus a 2px left marker. */
  selected?: boolean;
  /** Primary-ink label, medium weight, and a 6px dot. */
  unread?: boolean;
  /** Like unread, but with an accent diamond; the only thing that breaks through mute. */
  mentioned?: boolean;
  /** Dims leading and trailing to 62% and suppresses the unread lift. */
  muted?: boolean;
  /** 44px row instead of 30px. */
  touch?: boolean;
  /** Minimum height in px. */
  height?: number;
}

/** The channel, member and settings row: leading slot, label with optional subtitle, meta, trailing slot. Selection is an accent-soft fill with a 2px left marker; unread and mentioned lift the label and add a dot. */
export function ListRow({
  label,
  leading,
  subtitle,
  subtitleIcon,
  meta,
  trailing,
  trailingExtra,
  selected = false,
  unread = false,
  mentioned = false,
  muted = false,
  touch = false,
  height,
  className,
  style,
  onClick,
  ...rest
}: ListRowProps) {
  const emphasised = selected || mentioned || (unread && !muted);
  const classes = [
    'sm-listrow',
    touch && 'sm-listrow--touch',
    subtitle && 'sm-listrow--two-line',
    selected && 'sm-listrow--selected',
    emphasised && 'sm-listrow--emphasised',
    muted && 'sm-listrow--muted',
    onClick && 'sm-listrow--interactive',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  const dot = unread || mentioned ? <span className={mentioned ? 'sm-listrow__mention' : 'sm-listrow__unread'} /> : null;
  const tail = trailing ?? dot;
  return (
    <div
      className={classes}
      style={height ? { minHeight: height, ...style } : style}
      role={onClick ? 'button' : undefined}
      tabIndex={onClick ? 0 : undefined}
      aria-current={selected || undefined}
      onClick={onClick}
      onKeyDown={(e) => {
        if (onClick && (e.key === 'Enter' || e.key === ' ')) {
          e.preventDefault();
          e.currentTarget.click();
        }
      }}
      {...rest}
    >
      {selected && <span className="sm-listrow__marker" aria-hidden />}
      {leading && <span className="sm-listrow__leading">{leading}</span>}
      <span className="sm-listrow__text">
        <span className="sm-listrow__label">{label}</span>
        {subtitle && (
          <span className="sm-listrow__subtitle">
            {subtitleIcon && <Icon name={subtitleIcon} size={16} className="sm-listrow__subtitle-icon" />}
            <span className="sm-listrow__subtitle-text">{subtitle}</span>
          </span>
        )}
      </span>
      {meta && <span className="sm-listrow__meta">{meta}</span>}
      {tail && <span className="sm-listrow__trailing">{tail}</span>}
      {trailingExtra}
    </div>
  );
}

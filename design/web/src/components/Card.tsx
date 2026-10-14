import type { HTMLAttributes, ReactNode } from 'react';

export interface CardProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  /** Uppercase micro-label header with its own bottom hairline. */
  title?: string;
  /** Pinned to the end of the title row; ignored without a title. */
  action?: ReactNode;
  /** Adds the float shadow, only for a surface that genuinely floats. */
  floating?: boolean;
  /** Uses the sunken fill, for a card nested inside an already-raised surface. */
  sunken?: boolean;
  /** Body padding in px; defaults to 16. */
  padding?: number;
  children?: ReactNode;
}

/** A hairline-bordered content surface with a 10px radius and no shadow, for grouping related content off the plain background. Not clickable: build a clickable card from it. */
export function Card({ title, action, floating = false, sunken = false, padding, className, style, children, ...rest }: CardProps) {
  const classes = ['sm-card', sunken && 'sm-card--sunken', floating && 'sm-card--floating', className].filter(Boolean).join(' ');
  return (
    <div className={classes} style={style} {...rest}>
      {title != null && (
        <div className="sm-card__header">
          <span className="sm-card__title">{title}</span>
          {action}
        </div>
      )}
      <div className="sm-card__body" style={padding == null ? undefined : { padding }}>
        {children}
      </div>
    </div>
  );
}

import { Children, Fragment, type HTMLAttributes, type ReactNode } from 'react';

export interface SettingsSectionCardProps extends Omit<HTMLAttributes<HTMLElement>, 'title'> {
  /** Omit on a screen whose whole body is this one group; a header would only repeat the app bar. */
  title?: string;
  /** Rendered under the title, so it needs a title to appear. */
  description?: string;
  /** Hairline between children, for a card that is a list of rows. */
  divided?: boolean;
  children?: ReactNode;
}

/** The container every settings and admin screen is built from: a semibold title and optional description above a bordered card holding the rows. A screen is a stack of these. */
export function SettingsSectionCard({ title, description, divided = false, children, className, ...rest }: SettingsSectionCardProps) {
  const items = Children.toArray(children);
  return (
    <section className={['sm-settings-section', className].filter(Boolean).join(' ')} {...rest}>
      {title ? (
        <header className="sm-settings-section__header">
          <h3 className="sm-settings-section__title">{title}</h3>
          {description && <p className="sm-settings-section__description">{description}</p>}
        </header>
      ) : (
        <div className="sm-settings-section__spacer" />
      )}
      <div className="sm-settings-section__card">
        {items.map((child, i) => (
          <Fragment key={i}>
            {divided && i > 0 && <hr className="sm-settings-section__rule" />}
            {child}
          </Fragment>
        ))}
      </div>
    </section>
  );
}

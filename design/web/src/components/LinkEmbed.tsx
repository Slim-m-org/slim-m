import type { HTMLAttributes } from 'react';
import { Icon } from './Icon';

export interface LinkEmbedProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children' | 'title'> {
  siteName?: string;
  title?: string;
  description?: string;
  /** Account name shown with a person glyph under the title. */
  authorName?: string;
  /** An image URL, or `true` for the striped stand-in block. */
  image?: string | boolean;
}

/** The unfurled preview of a link under a message: site name, a two-line title, a three-line description and an optional image, in a hairline card with 6px corners and no fill. Never wider than the 760px message column, and it shrinks to the column at any width. */
export function LinkEmbed({ siteName, title, description, authorName, image, className, ...rest }: LinkEmbedProps) {
  return (
    <div className={['sm-link-embed', className].filter(Boolean).join(' ')} role="link" {...rest}>
      {siteName && (
        <div className="sm-link-embed__site">
          <Icon name="link" size={16} width={12} height={12} />
          <span className="sm-link-embed__site-name">{siteName}</span>
        </div>
      )}
      {title && <div className="sm-link-embed__title">{title}</div>}
      {authorName && (
        <div className="sm-link-embed__author">
          <Icon name="account" size={16} width={12} height={12} />
          <span className="sm-link-embed__site-name">{authorName}</span>
        </div>
      )}
      {description && <div className="sm-link-embed__description">{description}</div>}
      {image &&
        (typeof image === 'string' ? (
          <img className="sm-link-embed__image" src={image} alt="" />
        ) : (
          <div className="sm-link-embed__image sm-link-embed__image--stand-in" aria-hidden />
        ))}
    </div>
  );
}

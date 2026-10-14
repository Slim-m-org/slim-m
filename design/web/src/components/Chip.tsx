import type { ButtonHTMLAttributes, ReactNode } from 'react';

export interface ChipProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
  /** The reaction emoji. User content only, never interface chrome. */
  emoji?: string;
  /** Drawn in place of the emoji text, for a reaction keyed by a custom shortcode. */
  glyph?: ReactNode;
  /** How many people reacted. */
  count: number;
  /** The current user is one of them: accent-soft fill and a heavier count, no accent outline. */
  active?: boolean;
}

/** The reaction chip: an emoji, a count, and whether you reacted. A 24px pill; the only chip the app has. */
export function Chip({ emoji, glyph, count, active = false, className, ...rest }: ChipProps) {
  const classes = ['sm-chip', active && 'sm-chip--active', !rest.onClick && 'sm-chip--static', className].filter(Boolean).join(' ');
  return (
    <button
      type="button"
      className={classes}
      aria-pressed={active}
      aria-label={`${emoji ?? ''} reaction, ${count}, ${active ? 'you reacted' : 'tap to react'}`}
      {...rest}
    >
      <span className="sm-chip__glyph">{glyph ?? emoji}</span>
      <span className="sm-chip__count">{count}</span>
    </button>
  );
}

import type { SVGAttributes } from 'react';
import { appIcons, type IconName } from '../icons';

export type { IconName };

export interface IconProps extends Omit<SVGAttributes<SVGSVGElement>, 'name'> {
  /** The app's own icon name, the same as Flutter's AppIcons (e.g. `micOff`, `hash`, `voice`). */
  name: IconName;
  /** 16 in rows and buttons, 20 in headers, 24 for standalone glyphs. */
  size?: 16 | 20 | 24 | 28 | 32;
  /** Defaults to the current text colour. */
  color?: string;
}

/** A Lucide icon at the app's 1.5 stroke, named the way the Flutter client names it. */
export function Icon({ name, size = 16, color = 'currentColor', ...rest }: IconProps) {
  const Glyph = appIcons[name];
  return <Glyph size={size} color={color} strokeWidth={1.5} aria-hidden {...rest} />;
}

/** Every icon name the app uses, for pickers and docs. */
export const iconNames = Object.keys(appIcons) as IconName[];

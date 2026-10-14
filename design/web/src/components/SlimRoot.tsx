import type { HTMLAttributes, ReactNode } from 'react';

export type Theme = 'dark' | 'light' | 'black';

export interface SlimRootProps extends HTMLAttributes<HTMLDivElement> {
  /** Dark is the default; black is true black for OLED, where borders carry all elevation. */
  theme?: Theme;
  children?: ReactNode;
}

/** The root every slim-m screen sits in: sets the theme's tokens, the base surface, and IBM Plex. */
export function SlimRoot({ theme = 'dark', className, children, ...rest }: SlimRootProps) {
  return (
    <div data-theme={theme} className={['sm-root', className].filter(Boolean).join(' ')} {...rest}>
      {children}
    </div>
  );
}

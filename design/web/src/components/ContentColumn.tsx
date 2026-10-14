import type { HTMLAttributes, ReactNode } from 'react';

export interface ContentColumnProps extends HTMLAttributes<HTMLDivElement> {
  /** Max width in px; defaults to 720. */
  maxWidth?: number;
  children?: ReactNode;
}

/** Centres its content and stops it growing past 720px, for settings and admin screens where a label and its value would otherwise sit a monitor apart. A no-op below that width. */
export function ContentColumn({ maxWidth = 720, className, style, children, ...rest }: ContentColumnProps) {
  return (
    <div className={['sm-content-column', className].filter(Boolean).join(' ')} style={{ maxWidth, ...style }} {...rest}>
      {children}
    </div>
  );
}

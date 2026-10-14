import type { HTMLAttributes } from 'react';

export interface TypingDotsProps extends HTMLAttributes<HTMLSpanElement> {
  /** Defaults to the secondary text colour, the label's own ink. */
  color?: string;
  /** Dot diameter in px. */
  dotSize?: number;
}

/** Three staggered pulsing dots for "someone is typing". Mount only while somebody is typing; static under reduced motion. */
export function TypingDots({ color, dotSize = 5, className, style, ...rest }: TypingDotsProps) {
  return (
    <span
      className={['sm-typing-dots', className].filter(Boolean).join(' ')}
      style={{ ...(color ? { color } : null), ['--sm-typing-dot' as string]: `${dotSize}px`, ...style }}
      aria-hidden
      {...rest}
    >
      <span className="sm-typing-dots__dot" />
      <span className="sm-typing-dots__dot" />
      <span className="sm-typing-dots__dot" />
    </span>
  );
}

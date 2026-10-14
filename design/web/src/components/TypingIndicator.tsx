import type { HTMLAttributes } from 'react';
import { TypingDots } from './TypingDots';

export interface TypingIndicatorProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** Display names of who is typing, never including the reader. Renders nothing when empty. */
  names: string[];
}

/** The "someone is typing" line above the composer: pulsing dots and a mono label, "Mara is typing..." or "Mara, kiki are typing...". Mount it only while someone types; it is the same at every width. */
export function TypingIndicator({ names, className, ...rest }: TypingIndicatorProps) {
  if (names.length === 0) return null;
  const sorted = [...names].sort();
  const label = sorted.length === 1 ? `${sorted[0]} is typing…` : `${sorted.join(', ')} are typing…`;
  return (
    <div className={['sm-typing-indicator', className].filter(Boolean).join(' ')} role="status" {...rest}>
      <TypingDots />
      <span className="sm-typing-indicator__label">{label}</span>
    </div>
  );
}

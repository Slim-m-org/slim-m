import type { HTMLAttributes } from 'react';

export interface KbdProps extends Omit<HTMLAttributes<HTMLElement>, 'children'> {
  label: string;
}

/** One keycap: a mono, hairline-bordered, never-filled chip. Place several side by side for a chord like Ctrl and K. */
export function Kbd({ label, className, ...rest }: KbdProps) {
  return (
    <kbd className={['sm-kbd', className].filter(Boolean).join(' ')} {...rest}>
      {label}
    </kbd>
  );
}

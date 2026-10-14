import type { HTMLAttributes } from 'react';

export interface DayDividerProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** The formatted day: "Today", "Yesterday", "July 28" or "July 28, 2025". */
  label: string;
}

/** The hairline band between two calendar days in the transcript, with the day in mono at the centre. Sits above the first message of a new day. Gutter is 20px at 600px and wider, 10px below. */
export function DayDivider({ label, className, ...rest }: DayDividerProps) {
  return (
    <div className={['sm-day-divider', className].filter(Boolean).join(' ')} role="separator" aria-label={label} {...rest}>
      <span className="sm-day-divider__rule" />
      <span className="sm-day-divider__label">{label}</span>
      <span className="sm-day-divider__rule" />
    </div>
  );
}

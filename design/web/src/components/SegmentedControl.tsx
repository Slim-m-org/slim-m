import type { HTMLAttributes } from 'react';

export interface SegmentedOption {
  label: string;
  /** Shown but not choosable, in the disabled text colour. */
  disabled?: boolean;
}

export interface SegmentedControlProps extends Omit<HTMLAttributes<HTMLDivElement>, 'onChange'> {
  options: SegmentedOption[];
  selectedIndex: number;
  onSegmentSelected?: (index: number) => void;
}

/** A row of 2-4 mutually exclusive options in a sunken trough; the selected one lifts to a raised chip with a hairline and medium weight. Selection is not accent-coloured. */
export function SegmentedControl({ options, selectedIndex, onSegmentSelected, className, ...rest }: SegmentedControlProps) {
  return (
    <div role="group" className={['sm-segmented', className].filter(Boolean).join(' ')} {...rest}>
      {options.map((option, index) => {
        const selected = index === selectedIndex;
        const classes = ['sm-segmented__segment', selected && 'sm-segmented__segment--selected'].filter(Boolean).join(' ');
        return (
          <button
            key={`${index}-${option.label}`}
            type="button"
            className={classes}
            aria-pressed={selected}
            disabled={option.disabled}
            onClick={() => onSegmentSelected?.(index)}
          >
            {option.label}
          </button>
        );
      })}
    </div>
  );
}

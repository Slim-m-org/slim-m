import type { HTMLAttributes } from 'react';
import { Badge } from './Badge';
import { Icon } from './Icon';

export interface PollOptionData {
  label: string;
  votes: number;
}

export interface PollViewProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  question: string;
  options: PollOptionData[];
  /** Index into `options` of the reader's own vote. */
  yourVote?: number;
  /** A closed poll shows the Closed badge and stops taking votes. */
  closed?: boolean;
  /** The remaining time sentence for an open poll, e.g. "Closes in 2 h.". */
  closesIn?: string;
}

function footer(total: number, closed: boolean, closesIn?: string): string {
  const votes = total === 0 ? (closed ? 'No one voted.' : 'No votes yet. Tap an option to vote.') : `${total} vote${total === 1 ? '' : 's'}`;
  if (closed || !closesIn) return votes;
  return total === 0 ? `${votes} ${closesIn}` : `${votes} - ${closesIn}`;
}

/** A poll inside a message: the question, one bar row per option with its percentage, a check on your own vote, a leading marker on the single top option, and a tally line. Capped at 360px. Rows are 34px at 600px and wider and 44px below, with the same bars. */
export function PollView({ question, options, yourVote, closed = false, closesIn, className, ...rest }: PollViewProps) {
  const total = options.reduce((sum, o) => sum + o.votes, 0);
  const top = Math.max(...options.map((o) => o.votes));
  const leaders = options.filter((o) => o.votes === top);
  const leading = total > 0 && top > 0 && leaders.length === 1 ? options.indexOf(leaders[0]) : -1;
  return (
    <div className={['sm-poll', className].filter(Boolean).join(' ')} {...rest}>
      <div className="sm-poll__head">
        <div className="sm-poll__question">{question}</div>
        {closed && <Badge variant="tag" label="Closed" />}
      </div>
      {options.map((option, i) => {
        const fraction = total > 0 ? option.votes / total : 0;
        const selected = yourVote === i;
        const emphasised = selected || leading === i;
        return (
          <div
            key={option.label}
            className={['sm-poll__option', !closed && 'sm-poll__option--open', emphasised && 'sm-poll__option--strong'].filter(Boolean).join(' ')}
            role="button"
            aria-disabled={closed}
            aria-pressed={selected}
          >
            <span className="sm-poll__bar" style={{ width: `${fraction * 100}%` }} />
            <span className="sm-poll__row">
              {selected && <Icon name="check" size={16} color="var(--accent-fill)" />}
              <span className="sm-poll__label">{option.label}</span>
              {total > 0 && (
                <span className="sm-poll__percent">
                  {leading === i && <Icon name="pollLeading" size={16} />}
                  {Math.round(fraction * 100)}%
                </span>
              )}
            </span>
          </div>
        );
      })}
      <div className="sm-poll__footer">{footer(total, closed, closesIn)}</div>
    </div>
  );
}

import type { HTMLAttributes } from 'react';
import { Button } from './Button';
import { ErrorState } from './ErrorState';

export interface VoiceJoinBarProps extends HTMLAttributes<HTMLDivElement> {
  /** Display names of the people in the call right now. */
  here?: string[];
  /** Channel members online but not in the call; shown in the subtitle. */
  online?: string[];
  /** When the last call ended, as a day label ("yesterday", "Tuesday"). Wide only. */
  lastCall?: string;
  /** A join failure. Shows the error state under the bar, and the button becomes "Try again". */
  errorMessage?: string;
  /** False hides the button when the failure cannot be retried. */
  canRetry?: boolean;
}

function joinNames(names: string[], one: string, many: string): string {
  if (names.length === 0) return '';
  if (names.length === 1) return `${names[0]} ${one}`;
  if (names.length === 2) return `${names[0]} and ${names[1]} ${many}`;
  return `${names[0]} and ${names.length - 1} others ${many}`;
}

/** The join card on an idle voice channel: who is here, who is online, and one primary Join. Joining always starts muted. Wide adds a mono status line and "Join · N here"; under 600px it keeps the title and a short "Join". */
export function VoiceJoinBar({ here = [], online = [], lastCall, errorMessage, canRetry = true, className, ...rest }: VoiceJoinBarProps) {
  const empty = here.length === 0;
  const title = empty ? null : joinNames(here, 'is here', 'are here');
  const onlineText = joinNames(online, 'is online', 'are online');
  const status = [empty ? 'empty' : `${here.length} in the call`, lastCall && `last call ${lastCall}`].filter(Boolean).join(' · ');
  const wideLabel = errorMessage ? 'Try again' : empty ? 'Join muted' : `Join · ${here.length} here`;
  return (
    <div className={['sm-voice-join-bar', className].filter(Boolean).join(' ')} {...rest}>
      <div className="sm-voice-join-bar__status">{status}</div>
      <div className="sm-voice-join-bar__row">
        <div className="sm-voice-join-bar__text">
          <div className="sm-voice-join-bar__title">
            {title ?? (
              <>
                <span className="sm-voice-join-bar__wide">Nobody's here right now</span>
                <span className="sm-voice-join-bar__compact">Nobody's here</span>
              </>
            )}
          </div>
          <div className="sm-voice-join-bar__subtitle">
            <span className="sm-voice-join-bar__wide">{[onlineText, 'joining starts you muted'].filter(Boolean).join(' \u00b7 ')}</span>
            <span className="sm-voice-join-bar__compact">{onlineText}</span>
          </div>
        </div>
        {(!errorMessage || canRetry) && (
          <Button variant="primary" label={wideLabel} className="sm-voice-join-bar__button sm-voice-join-bar__wide" />
        )}
        {(!errorMessage || canRetry) && (
          <Button variant="primary" label={errorMessage ? 'Try again' : 'Join'} className="sm-voice-join-bar__button sm-voice-join-bar__compact" />
        )}
      </div>
      {errorMessage && (
        <div className="sm-voice-join-bar__error">
          <ErrorState message={errorMessage} />
        </div>
      )}
    </div>
  );
}

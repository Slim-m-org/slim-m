import type { HTMLAttributes } from 'react';
import { Avatar } from './Avatar';
import { IconButton } from './IconButton';

export interface CallStripParticipant {
  name: string;
  speaking?: boolean;
}

export interface CallStripProps extends HTMLAttributes<HTMLDivElement> {
  /** Channel name of the call you are in. */
  channel: string;
  /** Up to the first two are drawn as 20px avatars. */
  participants?: CallStripParticipant[];
  /** Elapsed time as shown, e.g. "12:04". */
  duration?: string;
  sharing?: boolean;
  micOn?: boolean;
  deafened?: boolean;
  /** Strip sits at the top of the screen, so the hairline moves to its bottom edge. */
  atTop?: boolean;
}

/** The thin bar that shows you are still in a call while you look at another channel. The whole bar returns to the call; mic, deafen and leave sit on the right. Same layout at every width, though the app only mounts it on compact. */
export function CallStrip({ channel, participants = [], duration, sharing = false, micOn = true, deafened = false, atTop = false, className, ...rest }: CallStripProps) {
  const subtitle = duration ? (sharing ? ' - sharing' : ' - audio only') : sharing ? 'Sharing' : 'Audio only';
  return (
    <div className={['sm-call-strip', atTop && 'sm-call-strip--top', className].filter(Boolean).join(' ')} {...rest}>
      <button type="button" className="sm-call-strip__press" aria-label={['Return to call', channel, duration].filter(Boolean).join(', ')} />
      <div className="sm-call-strip__summary" aria-hidden>
        {participants.slice(0, 2).map((p) => (
          <span className="sm-call-strip__avatar" key={p.name}>
            <Avatar name={p.name} size={20} speaking={p.speaking} />
          </span>
        ))}
        <div className="sm-call-strip__text">
          <div className="sm-call-strip__channel">{channel}</div>
          <div className="sm-call-strip__facts">
            {duration && <span className="sm-call-strip__time">{duration}</span>}
            <span className={sharing ? 'sm-call-strip__sub sm-call-strip__sub--sharing' : 'sm-call-strip__sub'}>{subtitle}</span>
          </div>
        </div>
      </div>
      <div className="sm-call-strip__controls">
        <IconButton icon={micOn ? 'mic' : 'micOff'} label={micOn ? 'Mute' : 'Unmute'} iconSize={20} />
        <IconButton icon={deafened ? 'speakerOff' : 'headphones'} label={deafened ? 'Undeafen' : 'Deafen'} iconSize={20} />
        <IconButton icon="leaveCall" label="Leave call" variant="danger" iconSize={20} />
      </div>
    </div>
  );
}

import type { HTMLAttributes } from 'react';
import { Avatar } from './Avatar';
import { Button } from './Button';
import { CallDockButton } from './CallDock';

export interface IncomingCallProps extends HTMLAttributes<HTMLDivElement> {
  /** Caller's display name. */
  name: string;
  /** Stable id the avatar tint is hashed from. */
  tintKey?: string;
}

/** The ring for an incoming DM call, with Decline and Accept. At 600px and up it is a floating card at the top of the window; below that it is a full-screen takeover with a 96px avatar and two large buttons (desktop-vs-mobile rule 7). Give the compact form a frame with height. */
export function IncomingCall({ name, tintKey, className, ...rest }: IncomingCallProps) {
  return (
    <div className={['sm-incoming-call', className].filter(Boolean).join(' ')} role="alertdialog" aria-label={`Incoming call from ${name}`} {...rest}>
      <div className="sm-incoming-call__card">
        <Avatar name={name} tintKey={tintKey} size={32} />
        <div className="sm-incoming-call__who">
          <div className="sm-incoming-call__name">{name}</div>
          <div className="sm-incoming-call__sub">Incoming call</div>
        </div>
        <CallDockButton icon="leaveCall" label="Decline" destructive />
        <CallDockButton icon="startCall" label="Accept" active />
      </div>
      <div className="sm-incoming-call__takeover">
        <div className="sm-incoming-call__spacer" />
        <Avatar name={name} tintKey={tintKey} size={96} />
        <div className="sm-incoming-call__big-name">{name}</div>
        <div className="sm-incoming-call__sub sm-incoming-call__sub--body">Incoming call</div>
        <div className="sm-incoming-call__spacer" />
        <div className="sm-incoming-call__actions">
          <Button variant="danger" size="lg" full label="Decline" icon="leaveCall" />
          <Button variant="primary" size="lg" full label="Accept" icon="startCall" />
        </div>
      </div>
    </div>
  );
}

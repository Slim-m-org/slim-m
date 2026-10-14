import type { ButtonHTMLAttributes, HTMLAttributes } from 'react';
import { ControlWithOptions } from './ControlWithOptions';
import { Icon, type IconName } from './Icon';

export interface CallDockButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
  icon: IconName;
  /** Accessible name and tooltip text. */
  label: string;
  /** Accent-tinted: the thing is on (sharing, canvas open). */
  active?: boolean;
  /** Danger outline: leave, or a muted mic. */
  destructive?: boolean;
  /** Spinner in place of the glyph while a request is in flight. */
  pending?: boolean;
  /** Greyed glyph for a control the call cannot offer (listen-only). */
  unavailable?: boolean;
  /** Local mic level 0 to 1, drawn as a thin green bar under the glyph. */
  level?: number;
}

/** One 34px chip of the call dock. Used by CallDock and IncomingCall; reach for CallDock unless you are building a new call surface. */
export function CallDockButton({
  icon,
  label,
  active = false,
  destructive = false,
  pending = false,
  unavailable = false,
  level,
  className,
  ...rest
}: CallDockButtonProps) {
  const classes = [
    'sm-call-dock-button',
    active && 'sm-call-dock-button--active',
    destructive && 'sm-call-dock-button--destructive',
    unavailable && 'sm-call-dock-button--unavailable',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <button type="button" className={classes} aria-label={label} title={label} aria-pressed={active || undefined} {...rest}>
      <span className="sm-call-dock-button__chip">
        {pending ? <span className="sm-call-dock-button__spinner" aria-hidden /> : <Icon name={icon} size={16} />}
        {level !== undefined && !pending && (
          <span className="sm-call-dock-button__level" aria-hidden>
            <span style={{ width: `${Math.min(1, Math.max(0, level)) * 100}%` }} />
          </span>
        )}
      </span>
    </button>
  );
}

export interface CallDockProps extends HTMLAttributes<HTMLDivElement> {
  /** Microphone is live. A muted mic draws as a danger outline. */
  micOn?: boolean;
  /** Listen-only: mic and camera are greyed out. */
  listenOnly?: boolean;
  /** Local mic level 0 to 1 while the mic is on. */
  micLevel?: number;
  cameraOn?: boolean;
  /** Your screen is being shared. */
  sharing?: boolean;
  /** Show the switch-speaker button, where the platform can pick an output. */
  showSpeaker?: boolean;
  /** Show the switch-camera button, only while the camera is on. */
  showSwitchCamera?: boolean;
  /** Show the canvas toggle. Omit for calls with no Voice Canvas, such as DM calls. */
  canvasOpen?: boolean;
  showCanvas?: boolean;
  /** Put the canvas toggle on its own row above the controls, as the app does when one row will not fit. */
  stacked?: boolean;
  /** Draw the options caret beside screen share (pointer widths only; compact never shows it). */
  shareOptions?: boolean;
}

/** The in-call control bar: mic, camera, screen share with its options caret, canvas, and leave behind a divider. A floating card at every width; at compact the chips grow to 44px hit targets and the share caret goes away. */
export function CallDock({
  micOn = true,
  listenOnly = false,
  micLevel,
  cameraOn = false,
  sharing = false,
  showSpeaker = false,
  showSwitchCamera = false,
  canvasOpen = false,
  showCanvas = true,
  stacked = false,
  shareOptions = true,
  className,
  ...rest
}: CallDockProps) {
  const canvas = showCanvas && (
    <CallDockButton icon="canvas" label={canvasOpen ? 'Close canvas' : 'Open canvas'} active={canvasOpen} />
  );
  const share = (
    <CallDockButton
      icon="screenShare"
      label={sharing ? 'You are sharing your screen. Stop sharing' : 'Share a screen'}
      active={sharing}
    />
  );
  return (
    <div className={['sm-call-dock', className].filter(Boolean).join(' ')} role="group" aria-label="Call controls" {...rest}>
      {showCanvas && stacked && <div className="sm-call-dock__row sm-call-dock__row--solo">{canvas}</div>}
      <div className="sm-call-dock__row">
        <div className="sm-call-dock__controls">
          <CallDockButton
            icon={micOn && !listenOnly ? 'mic' : 'micOff'}
            label={micOn ? 'Mute' : 'Unmute'}
            destructive={!micOn && !listenOnly}
            unavailable={listenOnly}
            level={micOn && !listenOnly ? micLevel : undefined}
          />
          {showSpeaker && <CallDockButton icon="speaker" label="Switch speaker" />}
          <CallDockButton
            icon={cameraOn && !listenOnly ? 'camera' : 'cameraOff'}
            label={cameraOn ? 'Turn off camera' : 'Turn on camera'}
            unavailable={listenOnly}
          />
          {cameraOn && showSwitchCamera && <CallDockButton icon="switchCamera" label="Switch camera" />}
          <span className="sm-call-dock__share">
            <ControlWithOptions optionsLabel="Screen share options" active={sharing} onOpenOptions={shareOptions ? () => {} : undefined}>
              {share}
            </ControlWithOptions>
          </span>
          {showCanvas && !stacked && canvas}
        </div>
        <span className="sm-call-dock__divider" aria-hidden />
        <CallDockButton icon="leaveCall" label="Leave call" destructive />
      </div>
    </div>
  );
}

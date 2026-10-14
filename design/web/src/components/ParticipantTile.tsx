import type { HTMLAttributes } from 'react';
import { Avatar, type AvatarSize } from './Avatar';
import { Icon } from './Icon';

export type ParticipantVideo = 'camera' | 'screen';

export interface ParticipantTileProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  name: string;
  /** Appends " (you)" to the label. */
  local?: boolean;
  muted?: boolean;
  speaking?: boolean;
  /** Draws a striped video placeholder in place of the avatar. A camera tile is black with a white label; a screen tile is the same with the share badge. */
  video?: ParticipantVideo;
  /** Fixed tile width in px; height follows at 0.625. Omit to fill the parent, as inside ParticipantGrid. */
  width?: number;
  /** Avatar diameter when there is no video. Defaults to the largest size that fits the tile above the label. */
  avatarSize?: AvatarSize;
  /** Avatar diameter used under the compact breakpoint, when the grid halves the tile width. */
  compactAvatarSize?: AvatarSize;
}

const SIZES: AvatarSize[] = [16, 20, 24, 28, 32, 36, 40, 44, 56, 72, 96];
const ASPECT = 0.625;
const LABEL_BAND = 36;

function largestWithin(room: number): AvatarSize {
  let best: AvatarSize = SIZES[0];
  for (const s of SIZES) if (s <= room) best = s;
  return best;
}

/** A call tile: avatar centred on a raised card, or a striped video placeholder, with the name at the bottom and a mic or screen-share badge at the top right. The speaking avatar pulses its ring. */
export function ParticipantTile({
  name,
  local = false,
  muted = false,
  speaking = false,
  video,
  width,
  avatarSize,
  compactAvatarSize,
  className,
  style,
  ...rest
}: ParticipantTileProps) {
  const size = avatarSize ?? largestWithin((width ?? 144) * ASPECT - LABEL_BAND - 8);
  const badge = video === 'screen' ? 'screenShare' : muted ? 'micOff' : 'mic';
  const state = [local ? `${name}, you` : name, muted ? 'muted' : 'microphone on', speaking && 'speaking', video === 'screen' && 'sharing their screen']
    .filter(Boolean)
    .join(', ');
  const classes = ['sm-participant-tile', video && 'sm-participant-tile--video', speaking && video && 'sm-participant-tile--speaking', className].filter(Boolean).join(' ');
  return (
    <div className={classes} role="group" aria-label={state} style={{ width, ...style }} {...rest}>
      {video ? (
        <div className="sm-participant-tile__video">
          <span className="sm-participant-tile__caption">{video === 'screen' ? 'screen share' : 'camera feed'}</span>
        </div>
      ) : (
        <div className="sm-participant-tile__stage">
          <span className={compactAvatarSize ? 'sm-participant-tile__avatar sm-participant-tile__avatar--wide' : 'sm-participant-tile__avatar'}>
            <Avatar name={name} size={size} speaking={speaking} />
          </span>
          {compactAvatarSize && (
            <span className="sm-participant-tile__avatar sm-participant-tile__avatar--compact">
              <Avatar name={name} size={compactAvatarSize} speaking={speaking} />
            </span>
          )}
        </div>
      )}
      <span className="sm-participant-tile__label">
        <span className="sm-participant-tile__name">{name}</span>
        {local && <span className="sm-participant-tile__you">&nbsp;(you)</span>}
      </span>
      <span className={['sm-participant-tile__badge', !muted && 'sm-participant-tile__badge--live'].filter(Boolean).join(' ')} aria-hidden>
        <Icon name={badge} size={16} width={12} height={12} />
      </span>
    </div>
  );
}

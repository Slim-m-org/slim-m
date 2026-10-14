import type { HTMLAttributes } from 'react';
import { ParticipantTile, type ParticipantTileProps } from './ParticipantTile';

export interface ParticipantGridProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  participants: Array<Omit<ParticipantTileProps, 'width' | 'avatarSize' | 'compactAvatarSize'> & { id?: string }>;
}

/** The call's tile grid. Expanded and medium widths wrap 240px tiles in a centred row; under 600px it is two tiles across (one tile alone caps at 320px). Always 16px gaps. */
export function ParticipantGrid({ participants, className, ...rest }: ParticipantGridProps) {
  return (
    <div className={['sm-participant-grid', className].filter(Boolean).join(' ')} data-count={participants.length} {...rest}>
      {participants.map(({ id, ...tile }) => (
        <div className="sm-participant-grid__cell" key={id ?? tile.name}>
          <ParticipantTile {...tile} avatarSize={96} compactAvatarSize={56} />
        </div>
      ))}
    </div>
  );
}

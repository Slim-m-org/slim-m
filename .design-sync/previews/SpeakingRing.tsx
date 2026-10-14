import { SpeakingRing, Avatar, Icon } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const AroundAvatar = () => (
  <div style={row}>
    <SpeakingRing size={44}>
      <Avatar name="kiki" size={44} />
    </SpeakingRing>
    <SpeakingRing size={72}>
      <Avatar name="Mara Lindqvist" size={72} />
    </SpeakingRing>
  </div>
);

export const SquareChild = () => (
  <SpeakingRing size={56} round={false} radius={6}>
    <Avatar name="music-bot" shape="square" size={56} placeholder={<Icon name="speaker" size={24} />} />
  </SpeakingRing>
);

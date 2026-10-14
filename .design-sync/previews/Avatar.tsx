import { Avatar, Icon } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Sizes = () => (
  <div style={row}>
    {([20, 28, 36, 44, 56, 96] as const).map((s) => (
      <Avatar key={s} name="Mara Lindqvist" tintKey="u-mara" size={s} />
    ))}
  </div>
);

export const Shapes = () => (
  <div style={row}>
    <Avatar name="kiki" tintKey="u-kiki" size={44} />
    <Avatar name="release-bot" shape="square" size={44} placeholder={<Icon name="webhook" size={20} />} />
    <Avatar name="ci" shape="square" size={44} placeholder={<Icon name="code" size={20} />} />
  </div>
);

export const Presence = () => (
  <div style={row}>
    <Avatar name="Mara Lindqvist" size={44} status="online" />
    <Avatar name="kiki" size={44} status="away" />
    <Avatar name="Jonas Berg" size={44} status="dnd" />
    <Avatar name="Ola Nordin" size={44} status="offline" />
    <Avatar name="Sam Okoye" size={44} status="hidden" />
    <Avatar name="Tove Aas" size={44} status="online" mobileOnly />
  </div>
);

export const Rings = () => (
  <div style={row}>
    <Avatar name="kiki" size={56} speaking status="online" />
    <Avatar name="Mara Lindqvist" size={56} ringColor="var(--accent-fill)" />
    <Avatar name="deploy-bot" shape="square" size={56} speaking placeholder={<Icon name="webhook" size={24} />} />
  </div>
);

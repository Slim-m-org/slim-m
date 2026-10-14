import { Chip } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-4)', flexWrap: 'wrap' as const };

export const Reactions = () => (
  <div style={row}>
    <Chip emoji={'\u{1F44D}'} count={3} active />
    <Chip emoji={'\u{1F389}'} count={1} />
    <Chip emoji={'\u{2764}\u{FE0F}'} count={12} />
  </div>
);

export const Active = () => (
  <div style={row}>
    <Chip emoji={'\u{1F44D}'} count={2} />
    <Chip emoji={'\u{1F44D}'} count={3} active />
  </div>
);

export const Interactive = () => (
  <div style={row}>
    <Chip emoji={'\u{1F440}'} count={5} onClick={() => {}} />
    <Chip emoji={'\u{1F680}'} count={9} active onClick={() => {}} />
  </div>
);

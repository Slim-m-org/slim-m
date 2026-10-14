import { SettingsEmpty, SlimRoot } from '@slim-m/design-system';

export const Compact = () => (
  <SlimRoot style={{ width: 390, padding: 16, boxSizing: 'border-box' }}>
    <SettingsEmpty message="No invites yet." />
  </SlimRoot>
);

export const Wide = () => (
  <SlimRoot style={{ width: 720, padding: 16, boxSizing: 'border-box' }}>
    <SettingsEmpty message="No bots have been added to this space." />
  </SlimRoot>
);

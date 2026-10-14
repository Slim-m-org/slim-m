import { SegmentedControl } from '@slim-m/design-system';

export const Two = () => (
  <div style={{ width: 300 }}>
    <SegmentedControl options={[{ label: 'Voice activity' }, { label: 'Push to talk' }]} selectedIndex={0} />
  </div>
);

export const Three = () => (
  <div style={{ width: 300 }}>
    <SegmentedControl options={[{ label: 'Light' }, { label: 'Dark' }, { label: 'System' }]} selectedIndex={1} />
  </div>
);

export const WithDisabled = () => (
  <div style={{ width: 300 }}>
    <SegmentedControl options={[{ label: 'Compact' }, { label: 'Cozy' }, { label: 'Roomy', disabled: true }]} selectedIndex={0} />
  </div>
);

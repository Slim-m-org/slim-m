import { Slider } from '@slim-m/design-system';

const col = { display: 'flex', flexDirection: 'column' as const, gap: 'var(--space-16)', width: 320 };

export const Default = () => (
  <div style={col}>
    <Slider defaultValue={30} />
    <Slider defaultValue={75} />
  </div>
);

export const WithTicks = () => (
  <div style={col}>
    <Slider defaultValue={50} ticks={['80%', '100%', '120%']} />
  </div>
);

export const InputSensitivity = () => (
  <div style={col}>
    <Slider tall min={-90} max={0} defaultValue={-48} meter={35} />
  </div>
);

export const MutedMeter = () => (
  <div style={col}>
    <Slider tall muted min={-90} max={0} defaultValue={-48} meter={0} />
  </div>
);

export const Disabled = () => (
  <div style={col}>
    <Slider disabled defaultValue={60} />
  </div>
);

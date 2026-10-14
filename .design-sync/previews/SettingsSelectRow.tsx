import { SettingsSelectRow } from '@slim-m/design-system';

const card = { width: 380, border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-card)', background: 'var(--surface-raised)' };

export const Chosen = () => (
  <div style={card}><SettingsSelectRow label="Microphone" value="Built-in audio" /></div>
);

export const Unknown = () => (
  <div style={card}><SettingsSelectRow label="Speakers" /></div>
);

export const Stacked = () => (
  <div style={card}>
    <SettingsSelectRow label="Microphone" value="Built-in audio" />
    <SettingsSelectRow label="Camera" value="Integrated webcam" />
  </div>
);

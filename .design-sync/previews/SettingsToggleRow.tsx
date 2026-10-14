import { SettingsToggleRow } from '@slim-m/design-system';

const card = { width: 380, border: '1px solid var(--border-subtle)', borderRadius: 'var(--radius-card)', background: 'var(--surface-raised)' };

export const On = () => (
  <div style={card}><SettingsToggleRow label="Join and leave sounds" value /></div>
);

export const Off = () => (
  <div style={card}><SettingsToggleRow label="Hold a key to talk" value={false} /></div>
);

export const WithDescription = () => (
  <div style={card}>
    <SettingsToggleRow label="Even out loud sounds" description="Off automatically in busy calls." value />
  </div>
);

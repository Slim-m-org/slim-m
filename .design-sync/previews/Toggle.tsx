import { Toggle } from '@slim-m/design-system';

const row = { display: 'flex', alignItems: 'center', gap: 'var(--space-12)', color: 'var(--text-primary)', fontSize: 13 };

export const OnOff = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-12)' }}>
    <label style={row}><Toggle value aria-label="Join and leave sounds" />Join and leave sounds</label>
    <label style={row}><Toggle value={false} aria-label="Hold a key to talk" />Hold a key to talk</label>
  </div>
);

export const Locked = () => (
  <label style={row}><Toggle value locked aria-label="Call connected sound" />Call connected sound</label>
);

export const Interactive = () => (
  <label style={row}><Toggle value={false} onChange={() => {}} aria-label="Even out loud sounds" />Even out loud sounds</label>
);

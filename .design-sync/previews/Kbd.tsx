import { Kbd } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Chords = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-12)' }}>
    <span style={{ display: 'inline-flex', gap: 'var(--space-4)' }}><Kbd label="Ctrl" /><Kbd label="K" /></span>
    <span style={{ display: 'inline-flex', gap: 'var(--space-4)' }}><Kbd label="Ctrl" /><Kbd label="Shift" /><Kbd label="M" /></span>
    <span style={{ display: 'inline-flex', gap: 'var(--space-4)' }}><Kbd label="Esc" /></span>
  </div>
);

export const InHint = () => (
  <div style={row}>
    <span>Quick switcher</span>
    <Kbd label="Ctrl" />
    <Kbd label="K" />
    <span style={{ marginLeft: 'var(--space-16)' }}>Send</span>
    <Kbd label="Enter" />
  </div>
);

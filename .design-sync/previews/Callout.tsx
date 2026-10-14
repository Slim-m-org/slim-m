import { Callout } from '@slim-m/design-system';

const col = { display: 'flex', flexDirection: 'column' as const, gap: 'var(--space-8)', width: 420 };

export const Tones = () => (
  <div style={col}>
    <Callout tone="warn">This invite expires in 2 hours.</Callout>
    <Callout tone="info">Messages older than 30 days are removed automatically.</Callout>
    <Callout tone="accent">Voice rooms now open from the lobby channel.</Callout>
  </div>
);

export const CustomIcon = () => (
  <div style={col}>
    <Callout tone="info" icon="shield">Only members with Manage Server can change this.</Callout>
  </div>
);

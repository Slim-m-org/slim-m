import { Badge } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Variants = () => (
  <div style={row}>
    <Badge variant="role" label="Admin" />
    <Badge variant="role" label="Moderator" />
    <Badge variant="tag" label="Bot" />
    <Badge variant="warn" label="Stale" icon="warning" />
  </div>
);

export const WithIcon = () => (
  <div style={row}>
    <Badge variant="role" label="Owner" icon="shield" />
    <Badge variant="tag" label="Webhook" icon="webhook" />
  </div>
);

export const NextToName = () => (
  <div style={row}>
    <span>Mara Lindqvist</span>
    <Badge variant="role" label="Admin" />
    <span style={{ marginLeft: 'var(--space-16)' }}>jellyfin</span>
    <Badge variant="tag" label="Bot" />
  </div>
);

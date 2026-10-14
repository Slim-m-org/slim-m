import { SlimRoot, Button, Icon } from '@slim-m/design-system';

const panel = (label: string) => (
  <div style={{ display: 'grid', gap: 'var(--space-8)', width: 240 }}>
    <div className="sm-label">{label}</div>
    <div style={{ background: 'var(--surface-raised)', border: 'var(--hairline)', borderRadius: 'var(--radius-card)', padding: 'var(--space-12)', display: 'grid', gap: 'var(--space-8)' }}>
      <span style={{ fontSize: 'var(--text-body)' }}>Welcome to slim-m</span>
      <span style={{ color: 'var(--text-secondary)' }}>
        <Icon name="hash" /> general
      </span>
      <Button variant="primary" label="Join call" icon="voice" />
    </div>
  </div>
);

export const Themes = () => (
  <div style={{ display: 'flex', gap: 'var(--space-12)', flexWrap: 'wrap' }}>
    <SlimRoot theme="dark" style={{ padding: 16, width: 272 }}>{panel('Dark')}</SlimRoot>
    <SlimRoot theme="light" style={{ padding: 16, width: 272 }}>{panel('Light')}</SlimRoot>
    <SlimRoot theme="black" style={{ padding: 16, width: 272 }}>{panel('True black')}</SlimRoot>
  </div>
);

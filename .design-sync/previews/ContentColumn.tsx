import { Card, ContentColumn } from '@slim-m/design-system';

export const Centred = () => (
  <div style={{ width: 640, background: 'var(--bg-sunken, transparent)' }}>
    <ContentColumn maxWidth={420}>
      <Card title="Server name">
        <div>Tidepool</div>
      </Card>
    </ContentColumn>
  </div>
);

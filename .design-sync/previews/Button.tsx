import { Button } from '@slim-m/design-system';

const row = { display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' as const };

export const Variants = () => (
  <div style={row}>
    <Button variant="primary" label="Join call" icon="voice" />
    <Button variant="secondary" label="Invite" />
    <Button variant="soft" label="Following" icon="check" />
    <Button variant="ghost" label="Cancel" />
    <Button variant="danger" label="Leave server" />
  </div>
);

export const Sizes = () => (
  <div style={row}>
    <Button size="sm" label="Small" />
    <Button size="md" label="Medium" />
    <Button size="lg" variant="primary" label="Large" />
  </div>
);

export const States = () => (
  <div style={row}>
    <Button variant="primary" label="Saving" busy />
    <Button variant="secondary" label="Unavailable" disabled />
  </div>
);

export const FullWidth = () => (
  <div style={{ width: 280 }}>
    <Button variant="primary" label="Create account" full />
  </div>
);

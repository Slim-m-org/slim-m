import { Button, Card } from '@slim-m/design-system';

export const Default = () => (
  <Card>
    <div>Anyone with the link can join Tidepool until it expires.</div>
  </Card>
);

export const Titled = () => (
  <Card title="Invite link" action={<Button size="sm" label="Copy" />}>
    <div>slim.example.org/invite/k3x9q2</div>
  </Card>
);

export const Sunken = () => (
  <Card title="Server">
    <Card sunken padding={12}>
      <div>14 members online</div>
    </Card>
  </Card>
);

export const Floating = () => (
  <Card floating title="Canvas window">
    <div>Sketch for the lobby layout</div>
  </Card>
);

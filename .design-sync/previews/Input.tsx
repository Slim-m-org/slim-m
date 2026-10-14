import { Input, Icon } from '@slim-m/design-system';

const col = { display: 'flex', flexDirection: 'column' as const, gap: 'var(--space-12)', width: 300 };

export const Sizes = () => (
  <div style={col}>
    <Input size="sm" placeholder="Small" />
    <Input size="md" placeholder="Medium" />
    <Input size="lg" placeholder="Large" />
  </div>
);

export const WithIcon = () => (
  <div style={col}>
    <Input icon={<Icon name="search" />} placeholder="Search messages" />
  </div>
);

export const Labelled = () => (
  <div style={col}>
    <Input label="Server address" mono defaultValue="slim.example.com" />
  </div>
);

export const Error = () => (
  <div style={col}>
    <Input label="Invite code" mono defaultValue="abcd-1234" errorText="That code has expired." />
  </div>
);

export const Multiline = () => (
  <div style={col}>
    <Input label="About you" multiline minLines={3} counterMax={190} defaultValue="Plays too much Factorio." />
  </div>
);

export const Disabled = () => (
  <div style={col}>
    <Input label="Username" disabled defaultValue="nick" />
  </div>
);

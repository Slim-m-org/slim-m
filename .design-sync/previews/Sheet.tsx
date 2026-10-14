import { Button, MenuItem, Sheet } from '@slim-m/design-system';

export const MessageActions = () => (
  <Sheet scrim title="Message actions">
    <div style={{ display: 'grid' }}>
      <MenuItem touch icon="reply" label="Reply" />
      <MenuItem touch icon="copy" label="Copy text" />
      <MenuItem touch icon="pin" label="Pin message" />
      <MenuItem touch icon="delete" label="Delete message" tone="danger" />
    </div>
  </Sheet>
);

export const WithFooter = () => (
  <Sheet scrim title="Leave voice-lobby?" footer={<Button variant="danger" full label="Leave call" />}>
    <p style={{ margin: 0, padding: '0 var(--space-8)', color: 'var(--text-secondary)', fontSize: 'var(--text-body)', lineHeight: 'var(--leading-body)' }}>
      You will stop hearing the call. The canvas stays as it is for everyone else.
    </p>
  </Sheet>
);

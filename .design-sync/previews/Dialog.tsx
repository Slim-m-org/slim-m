import { Button, Dialog } from '@slim-m/design-system';

export const ConfirmDelete = () => (
  <Dialog
    scrim
    title="Delete channel"
    actions={
      <>
        <Button variant="ghost" label="Cancel" />
        <Button variant="danger" label="Delete channel" />
      </>
    }
  >
    <p style={{ margin: 0 }}>Messages in #design-review will be removed for everyone. This cannot be undone.</p>
  </Dialog>
);

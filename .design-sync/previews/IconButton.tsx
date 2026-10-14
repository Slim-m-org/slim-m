import { IconButton } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Variants = () => (
  <div style={row}>
    <IconButton icon="search" label="Search" />
    <IconButton icon="delete" label="Delete message" variant="danger" />
    <IconButton icon="delete" label="Delete message" variant="dangerGhost" />
  </div>
);

export const Sizes = () => (
  <div style={row}>
    <IconButton icon="pin" label="Pinned" size="sm" />
    <IconButton icon="pin" label="Pinned" size="md" />
    <IconButton icon="pin" label="Pinned" size="touch" />
  </div>
);

export const States = () => (
  <div style={row}>
    <IconButton icon="pin" label="Pinned messages" active />
    <IconButton icon="mentions" label="Mentions" />
    <IconButton icon="moreHorizontal" label="More" disabled />
  </div>
);

export const Toolbar = () => (
  <div style={{ ...row, gap: 'var(--space-4)' }}>
    <IconButton icon="thread" label="Threads" />
    <IconButton icon="notificationsOn" label="Notifications" />
    <IconButton icon="pin" label="Pinned" />
    <IconButton icon="members" label="Member list" active />
  </div>
);

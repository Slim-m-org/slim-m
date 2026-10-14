import { Kbd, Menu, MenuItem } from '@slim-m/design-system';

export const Tones = () => (
  <Menu width={230}>
    <MenuItem icon="edit" label="Edit message" />
    <MenuItem icon="report" label="Report message" tone="warn" />
    <MenuItem icon="delete" label="Delete message" tone="danger" />
  </Menu>
);

export const SelectedAndTrailing = () => (
  <Menu width={230}>
    <MenuItem label="Newest first" selected />
    <MenuItem label="Oldest first" />
    <MenuItem icon="pin" label="Pin message" trailing={<Kbd label="P" />} />
    <MenuItem icon="notificationsOff" label="Mute for" submenu />
  </Menu>
);

export const Touch = () => (
  <Menu width={300} floating={false}>
    <MenuItem touch icon="reply" label="Reply" />
    <MenuItem touch icon="delete" label="Delete message" tone="danger" />
  </Menu>
);

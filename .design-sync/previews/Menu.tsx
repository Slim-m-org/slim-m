import { Menu, MenuDivider, MenuItem } from '@slim-m/design-system';

export const MessageActions = () => (
  <Menu width={230}>
    <MenuItem icon="reply" label="Reply" />
    <MenuItem icon="copy" label="Copy text" />
    <MenuItem icon="pin" label="Pin message" />
    <MenuDivider />
    <MenuItem icon="report" label="Report message" tone="warn" />
    <MenuItem icon="delete" label="Delete message" tone="danger" />
  </Menu>
);

export const Submenu = () => (
  <Menu width={230}>
    <MenuItem icon="notificationsOff" label="Mute channel" submenu />
    <MenuItem icon="invite" label="Invite people" />
    <MenuItem icon="settings" label="Channel settings" />
  </Menu>
);

export const Inline = () => (
  <Menu width={230} floating={false}>
    <MenuItem label="Online" selected />
    <MenuItem label="Away" />
    <MenuItem label="Do not disturb" />
  </Menu>
);

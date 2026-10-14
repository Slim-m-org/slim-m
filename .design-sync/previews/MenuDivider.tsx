import { Menu, MenuDivider, MenuItem } from '@slim-m/design-system';

export const BetweenGroups = () => (
  <Menu width={230}>
    <MenuItem icon="copy" label="Copy link" />
    <MenuItem icon="link" label="Open in browser" />
    <MenuDivider />
    <MenuItem icon="signOut" label="Leave server" tone="danger" />
  </Menu>
);

import { Menu, MenuItem, MenuLabel } from '@slim-m/design-system';

export const Sections = () => (
  <Menu width={230}>
    <MenuLabel>Sort by</MenuLabel>
    <MenuItem label="Newest first" selected />
    <MenuItem label="Oldest first" />
    <MenuLabel>Show</MenuLabel>
    <MenuItem label="All channels" />
    <MenuItem label="Unread only" />
  </Menu>
);

import { Menu, MenuFootnote, MenuItem } from '@slim-m/design-system';

export const Caveat = () => (
  <Menu width={260}>
    <MenuItem label="Everyone" selected />
    <MenuItem label="Only me" />
    <MenuFootnote>Applies to new messages only.</MenuFootnote>
  </Menu>
);

---
category: Surfaces
---

# Menu

The floating menu panel: raised surface, strong 1px edge, 10px radius and the menu shadow. Context menus, dropdowns and long-press sheets share it.

## Parts

- MenuItem: one row.
- MenuLabel: an uppercase micro section label.
- MenuFootnote: a sentence-case caveat under the choices.
- MenuDivider: a hairline between groups.

## Usage

```jsx
<Menu width={220}>
  <MenuItem icon="reply" label="Reply" />
  <MenuItem icon="copy" label="Copy link" />
  <MenuDivider />
  <MenuItem icon="delete" label="Delete message" tone="danger" />
</Menu>
```

- `width` is in px and defaults to 250.
- `floating` (default true) adds the shadow; turn it off for a menu embedded inline.

## Rules

- Put destructive items last, after a divider, with `tone="danger"`.
- Every item that has a clear glyph gets an icon; keep the set consistent within one menu.
- Do not use a menu for a primary action. That is a Button.

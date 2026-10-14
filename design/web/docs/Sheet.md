---
category: Surfaces
---

# Sheet

The open bottom sheet panel as used on a phone: full width, a drag handle and a raised surface. It is rendered statically, not as a portal. Wider windows get a Dialog instead.

## Usage

```jsx
<Sheet
  scrim
  title="Message actions"
  footer={<Button variant="primary" full label="Done" />}
>
  <Menu floating={false} width={440}>
    <MenuItem touch icon="reply" label="Reply" />
    <MenuItem touch icon="copy" label="Copy text" />
  </Menu>
</Sheet>
```

- `title` is optional. `footer` is an action row, usually one primary Button.
- `scrim` draws the dimmed backdrop and anchors the sheet to the bottom of its own box, to mock the open state in context.

## Rules

- Choose Sheet or Dialog by window width, not by platform.
- Menus inside a sheet use `touch` items and are not floating.

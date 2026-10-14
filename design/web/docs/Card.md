---
category: Surfaces
---

# Card

A hairline-bordered content surface with a 10px radius and no shadow. It groups related content off the plain background.

## Variants

- Default: raised fill, 1px border, no shadow. Elevation in slim-m is border-first.
- `sunken`: the sunken fill, for a card nested inside an already-raised surface.
- `floating`: adds the one float shadow. Use it only for a surface that really floats, such as a dragged canvas window.

## Usage

```jsx
<Card title="Invite link" action={<Button size="sm" label="Copy" />}>
  <p>Anyone with this link can join the server.</p>
</Card>
```

- `title` draws an uppercase micro-label header with its own bottom hairline. `action` sits at the end of that row and is ignored without a title.
- `padding` sets the body padding in px and defaults to 16.
- A Card is not clickable. Build a clickable card from it.

## Rules

- Do not add a shadow to separate a card from the page. Use the border.
- Do not stack more than one nesting level; the second level is `sunken`.
- Settings groups use SettingsSectionCard, not a bare Card.

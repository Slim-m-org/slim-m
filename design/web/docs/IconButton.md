---
category: Core
---

# IconButton

A square icon-only button for header actions, toolbars and message-row hover actions. Corners are 6px (10px at touch size), never a circle.

## Variants and sizes

- `ghost` (default): quiet until hovered.
- `danger`: states the destructive consequence at rest.
- `dangerGhost`: withholds the danger colour until hover; use it for hover actions like Delete on a message.
- `size`: `sm` 26px, `md` 28px, `touch` 38px.

## Usage

```jsx
<div style={{ display: 'flex', gap: 'var(--space-4)' }}>
  <IconButton icon="search" label="Search" />
  <IconButton icon="pin" label="Pinned messages" active />
  <IconButton icon="delete" label="Delete message" variant="dangerGhost" />
</div>
```

- `label` is required and becomes the accessible name and tooltip.
- `active` is a persistent accent-tinted state (a toggle on, a filter applied). It is not keyboard focus.
- `touch` grows the hit box to 44px without growing the glyph; use it on phone layouts.
- `iconSize` is 16, 20 (default) or 24.
- Use a labelled `Button` instead when the action needs words.

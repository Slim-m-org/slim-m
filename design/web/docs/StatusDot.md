---
category: Core
---

# StatusDot

A presence dot. Each state has its own silhouette as well as its own colour, so it reads in greyscale.

## States

- `online`: a filled disc.
- `away`: a triangle.
- `dnd`: a notched square (do not disturb).
- `offline`: a hollow ring.
- `hidden`: a slashed ring, for someone appearing offline.
- `unknown`: draws nothing.

## Usage

```jsx
<div style={{ display: 'flex', gap: 'var(--space-12)', alignItems: 'center' }}>
  <StatusDot status="online" />
  <StatusDot status="dnd" size={12} />
</div>
```

- `size` is the diameter in px, 10 by default.
- `backgroundColor` should match the surface the dot sits on, because the dnd notch and hidden slash are punched out in that colour.
- On a picture, let `Avatar` draw the dot through its `status` prop instead of placing one by hand.
- Never rely on colour alone; keep the shapes.

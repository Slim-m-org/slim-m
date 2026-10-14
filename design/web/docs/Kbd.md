---
category: Core
---

# Kbd

One keycap: a mono, hairline-bordered chip that is never filled. Place several side by side for a chord.

## Usage

```jsx
<span style={{ display: 'inline-flex', gap: 'var(--space-4)' }}>
  <Kbd label="Ctrl" />
  <Kbd label="K" />
</span>
```

- `label` is the only prop that matters; one `Kbd` per key.
- Use it in shortcut hints, menus and the keyboard settings page.
- Write modifier names as the platform shows them (Ctrl, Shift, Alt, Enter).
- Do not use it for general emphasis or inline code.

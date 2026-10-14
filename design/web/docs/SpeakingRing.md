---
category: Core
---

# SpeakingRing

A 2px accent ring pulsing at 600ms around its child. Under reduced motion it holds still and gains a small bar glyph so the state is not colour-only.

## Usage

```jsx
<SpeakingRing size={44}>
  <Avatar name="kiki" size={44} />
</SpeakingRing>
```

- `size` is the side of the square child.
- `round` (default) suits an avatar circle; set `round={false}` with `radius` for a rounded square such as a bot avatar.
- `color` overrides the accent ring colour.
- Mount it only while someone is speaking; remove it when they stop.
- `Avatar` already wraps itself with this when you pass `speaking`, so reach for `SpeakingRing` directly only for non-avatar tiles.

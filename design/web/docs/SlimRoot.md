---
category: Foundations
---

# SlimRoot

The root every slim-m screen sits in. It sets `data-theme`, which switches every colour token, and applies the base surface, IBM Plex Sans and the 14px UI type step.

```jsx
<SlimRoot theme="dark" style={{ minHeight: '100vh' }}>
  {/* the whole screen */}
</SlimRoot>
```

- `theme`: `dark` (default), `light`, or `black`. True black is not darker dark: every fill is #000 and hairline borders carry all elevation, so never add shadows or lighter fills to compensate.
- Wrap the whole mock once. Components still render with the dark tokens outside it, but light and black themes only apply inside a SlimRoot (or any element with `data-theme`).
- Two themes side by side is two SlimRoots.

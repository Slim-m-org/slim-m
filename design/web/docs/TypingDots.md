---
category: Core
---

# TypingDots

Three staggered pulsing dots for "someone is typing". They are static under reduced motion.

## Usage

```jsx
<div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-8)', color: 'var(--text-secondary)' }}>
  <TypingDots />
  <span>kiki is typing</span>
</div>
```

- `dotSize` is the dot diameter in px, 5 by default.
- `color` defaults to the secondary text colour, so the dots match the label beside them.
- Mount it only while somebody is typing, and always pair it with a text label naming who.

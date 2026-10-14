---
category: Foundations
---

# Icon

A Lucide icon at the app's 1.5 stroke, named exactly the way the Flutter client names it in `AppIcons`. Icons are never emoji and never Material.

```jsx
<Icon name="hash" />            {/* text channel */}
<Icon name="voice" size={20} /> {/* voice channel, in a header */}
<Icon name="micOff" color="var(--danger-text)" />
```

- `size`: 16 in rows, buttons and inputs; 20 in headers and the call dock; 24 for standalone glyphs such as empty states.
- Colour follows the text by default. Use `var(--text-secondary)` for resting glyphs and `var(--accent-text)` only for the accent roles (active channel, live voice).
- `iconNames` lists every valid name. Common ones: `hash`, `voice`, `settings`, `members`, `mic`, `micOff`, `headphones`, `camera`, `screenShare`, `send`, `search`, `chevronRight`, `check`, `pin`, `reply`, `add`, `dismiss`, `moreHorizontal`, `leaveCall`, `warning`, `notificationsOn`.

---
category: Core
---

# Avatar

A user picture: round tinted initials for a person, a square with a placeholder for a bot or webhook. It can carry a presence dot and a speaking ring without moving layout.

## Shapes and sizes

- `circle` (default) is a person. With no `src` it shows the first two letters of `name` on a fixed muted tint hashed from `tintKey` (a user id), or from `name` when no key is given.
- `square` marks a non-human author such as a webhook or CI bot. Squares never show initials; pass `placeholder` for the content, usually an `Icon`.
- `size` is one of 16, 20, 24, 28, 32, 36, 40, 44, 56, 72, 96. 16 and 20 are rail rows, 28 a DM row, 32 a member row, 36 the default, 40 a message author, 56 a canvas bubble, 96 an incoming call.

## Usage

```jsx
<div style={{ display: 'flex', gap: 'var(--space-12)', alignItems: 'center' }}>
  <Avatar name="Mara Lindqvist" tintKey="u-mara" size={40} status="online" />
  <Avatar name="release-bot" shape="square" size={40} placeholder={<Icon name="webhook" size={20} />} />
  <Avatar name="kiki" size={40} speaking />
</div>
```

- `status` draws a presence dot at the bottom-right. `unknown` or no value draws nothing. `mobileOnly` turns an online dot into a phone glyph.
- `speaking` shows the pulsing accent ring and wins over `ringColor`, which draws a static 2px ring.
- Always give `name`; it is the accessible label.
- Use a presence dot from size 24 up; below that the dot would swamp the picture.
- Tints are fixed and muted on purpose. Do not pick a colour per person.

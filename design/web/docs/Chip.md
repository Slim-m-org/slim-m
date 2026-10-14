---
category: Forms
---

# Chip

The reaction chip: an emoji, a count and whether you reacted. A 24px pill, and the only chip the app has.

## States

- Default: someone reacted, you did not.
- `active`: you are one of the reactors. Accent-soft fill and a heavier count, no accent outline.
- With no `onClick` it renders static.

## Usage

```jsx
<div style={{ display: 'flex', gap: 'var(--space-4)' }}>
  <Chip emoji={'\u{1F44D}'} count={3} active onClick={toggleReaction} />
  <Chip emoji={'\u{1F389}'} count={1} onClick={toggleReaction} />
</div>
```

- `emoji` is user content only. Emoji never appear as interface chrome.
- `glyph` replaces the emoji text for a reaction keyed by a custom shortcode.
- `count` is required and is the number of people, including you when `active`.

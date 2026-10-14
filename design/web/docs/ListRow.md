---
category: Surfaces
---

# ListRow

The channel, member and settings row: a leading slot, a label with an optional subtitle, a meta caption and a trailing slot.

## States

- `selected`: accent-soft fill plus a 2px left marker. The current channel.
- `unread`: primary-ink label, medium weight and a 6px dot.
- `mentioned`: like unread with an accent diamond. It is the only state that breaks through mute.
- `muted`: dims leading and trailing to 62% and suppresses the unread lift.
- `touch`: a 44px row instead of 30px, for phones.

## Usage

```jsx
<ListRow
  label="general"
  leading={<Icon name="hash" size={16} />}
  unread
/>
<ListRow
  label="Maya Chen"
  subtitle="Playing Factorio"
  leading={<Avatar name="Maya Chen" size={28} status="online" />}
  meta="2m"
/>
```

- `trailing` replaces the automatic unread or mention dot; `trailingExtra` always renders after it, such as a hover action.
- `subtitleIcon` puts a small icon before the subtitle. `meta` is a short caption against the trailing edge.
- Passing `onClick` makes the row a keyboard-focusable button.

## Rules

- Selection is a fill and a marker, never a border box.
- Labels truncate with an ellipsis; do not wrap them.
- The mention diamond is one of the accent's roles; do not use it for other badges.

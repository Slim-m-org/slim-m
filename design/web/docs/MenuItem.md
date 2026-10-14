---
category: Surfaces
---

# MenuItem

One row in a Menu: optional icon, label, trailing content and a chevron for submenus.

## Tones

- `normal`: the icon is dimmed to secondary ink.
- `warn`: a caution; icon and label are tinted together.
- `danger`: destructive; icon and label are tinted together.

## Usage

```jsx
<MenuItem icon="notificationsOff" label="Mute channel" submenu />
<MenuItem label="Newest first" selected />
<MenuItem icon="pin" label="Pin message" trailing={<Kbd label="P" />} />
```

- `selected` fills the row and shows a trailing check for the current value.
- `trailing` takes the slot a check would use, such as a shortcut hint.
- `touch` makes a 48px row with body text, for long-press sheets.

## Rules

- Only use inside a Menu.
- Labels are sentence case and start with a verb where they act.

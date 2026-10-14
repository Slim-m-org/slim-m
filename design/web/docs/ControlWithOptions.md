---
category: Core
---

# ControlWithOptions

Wraps a control and, only when `onOpenOptions` is set, adds a chevron caret beside it. Right-click and long-press open the same options. A joined `IconButton` squares its right edge to meet the caret.

## Usage

```jsx
<ControlWithOptions optionsLabel="Screen share options" onOpenOptions={() => {}}>
  <IconButton icon="screenShare" label="Share screen" />
</ControlWithOptions>
```

- `optionsLabel` is required and names the caret.
- Without `onOpenOptions` the child renders untouched, with no caret and no extra width.
- `active` tints the caret to match an active primary beside it, such as a live screen share.
- `touch` grows the caret hit box to 44px. `visualHeight` sets its drawn height to match a primary that is not a full chip.
- Use it in the voice call controls for mic, camera and screen share, where the caret opens device or quality choices. The caller owns the menu.

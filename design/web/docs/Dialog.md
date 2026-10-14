---
category: Surfaces
---

# Dialog

The open in-window dialog panel, rendered statically rather than as a portal: raised surface, hairline border, 10px radius. Use it for confirms and short forms on wide windows.

## Usage

```jsx
<Dialog
  scrim
  title="Delete channel"
  actions={
    <>
      <Button variant="ghost" label="Cancel" />
      <Button variant="danger" label="Delete channel" />
    </>
  }
>
  <p>Messages in #general will be removed for everyone. This cannot be undone.</p>
</Dialog>
```

- `scrim` shows the panel over the dimmed window.
- `maxWidth` is in px and defaults to 460.
- `actions` is the bottom row, usually a ghost Cancel and one primary or danger Button.

## Rules

- A destructive action gets a Dialog confirm and a danger Button, never a primary one.
- Failures do not open a Dialog; they appear as ErrorState at the point of action.

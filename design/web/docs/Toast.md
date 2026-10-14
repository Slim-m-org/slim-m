---
category: Surfaces
---

# Toast

A transient confirmation such as "Copied" or "Saved", outlined in its severity tone over the raised surface and never filled.

## Severities

- `success`: a confirmation.
- `info` (default): neutral.
- `warning`: a non-failure caution.

There is no error severity. Failures use ErrorState.

## Usage

```jsx
<Toast severity="success" message="Invite link copied" />
<Toast severity="warning" message="Slow mode is on in this channel" onDismiss={() => {}} />
```

- `onDismiss` draws a dismiss glyph and makes the whole toast clickable.

## Rules

- Never use a toast or snackbar to report a failed request.
- Keep the message to a few words, sentence case.

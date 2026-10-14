---
category: Shell
---

# StatusBanner

A full-width strip for status the user did not ask for: offline, reconnecting, a timeout, an update.
It sits in the layout flow above the content it concerns and pushes that content down; it never overlays it.

## Tones

- `transient` (default): amber. Something that clears itself, like reconnecting to a call or being offline.
- `failure`: red, with a red rule under it. Attach it to the thing that failed and keep it until the user dismisses or retries.
- `info`: neutral. Something worth knowing with no urgency, such as an update being ready.

## Width

The strip is full width at every size. Under 600 it is at least 44px tall and tightens its side padding to 12px. There is no tooltip and no floating form.

## Usage

```jsx
<StatusBanner
  tone="info"
  message="A new version of slim-m is ready."
  actionLabel="Restart"
  onAction={restart}
  onDismiss={hide}
/>
```

- Keep `message` to one plain sentence; put a reason or time in `children` (a second line).
- One action at most. `onAction` shows the button, `actionLabel` names it (Retry by default).
- Never use a toast for an error. A failed action is a `failure` banner or an ErrorState next to what failed.
- Use `AppShell`'s `banner` slot to span the whole window, or place it as the first child of a column to scope it to one pane.

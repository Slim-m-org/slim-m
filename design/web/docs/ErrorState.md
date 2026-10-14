---
category: Surfaces
---

# ErrorState

The persistent record of a failed action. It is shown at the point of the action and kept until something changes it. It replaces snackbars. Outlined in the danger border, never filled.

## Usage

```jsx
<ErrorState
  message="Could not load messages. The server is unreachable."
  detail="GET /channels/general/messages - 503"
  onRetry={() => {}}
  onDismiss={() => {}}
/>
```

- `message` says what happened in plain words, never a raw exception.
- `detail` is a technical line for the server operator, set in mono.
- `onRetry` shows the Retry button and `onDismiss` shows Dismiss; pass a no-op in a mock. `retryLabel` and `dismissLabel` rename them.

## Rules

- Messages follow "Could not <what failed>." followed by a short reason.
- Place it where the user acted, not in a corner. Do not also show a toast.
- Failures are the one place danger red appears as an outline.

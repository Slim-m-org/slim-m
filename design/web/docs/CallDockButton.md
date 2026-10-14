---
category: Voice
---

# CallDockButton

One control in the `CallDock`: an icon button with the call's own states. Use it only inside a call surface (the dock, a participant tile's local controls, the incoming call card).

```jsx
<CallDockButton icon="micOff" label="Unmute" destructive />
<CallDockButton icon="screenShare" label="Stop sharing" active />
<CallDockButton icon="mic" label="Mute" level={0.6} />
```

- `destructive` is the danger outline for Leave and for a muted mic.
- `active` is the accent tint for something switched on (sharing, canvas open).
- `pending` shows a spinner while a request is in flight; `unavailable` greys a control the call cannot offer, such as the mic when listen-only.
- `level` draws your mic level (0 to 1) as a thin bar under the glyph.
- Hit targets grow from 30px to 44px below 600px wide, with the rest of the dock.

---
category: Voice
---

# CallStrip

The thin bar that shows you are still in a call while you are looking at another channel. Pressing anywhere on it returns to the call.

## Width behaviour

One layout at every width: a 44px minimum-height bar on the sunken surface with a hairline on the edge facing the content. The app mounts it on compact layouts above the nav (or at the top with `atTop`); wide layouts show the dock and the rail summary instead.

## Usage

```jsx
<CallStrip channel="voice-lobby" duration="12:04" participants={[{ name: 'Mara Lindqvist', speaking: true }, { name: 'kiki' }]} />
```

- Shows up to two 20px avatars; the speaking one pulses.
- Second line is the elapsed time, then " - audio only" or an accent " - sharing".
- Right side is mic, deafen and a danger leave. Mic and deafen are plain ghost buttons, with no danger styling when muted.

---
category: Voice
---

# CallDock

The in-call control bar: microphone, camera, screen share with its options caret, the Voice Canvas toggle, and Leave behind a divider. A floating card (raised, 16px radius, hairline, tile shadow) with 34px chips.

## Width behaviour

- 600px and up: 30px hit targets, and the screen share chip carries a caret for its options (quality, switch screen, stop sharing).
- Under 600px: the touch form. Hit targets grow to 44px and the caret goes away; a long press on the share chip opens the same options.
- When the controls will not fit one row (speaker and switch-camera both shown on a phone) the canvas toggle moves to its own row above. The app measures this; here you set `stacked`.

## Usage

```jsx
<CallDock micOn={false} cameraOn={false} sharing canvasOpen />
```

- A muted mic is a danger outline, not an accent. Sharing and canvas-open are accent-tinted.
- `micLevel` (0 to 1) draws a 2px green bar under the mic glyph while it is on.
- `listenOnly` greys the mic and camera.
- Leave is always last, always `danger`, separated by a 24px divider.
- Omit the canvas toggle (`showCanvas={false}`) for DM calls.
- Tooltips name the action and, on desktop, its shortcut: "Mute (Ctrl+Shift+M)".

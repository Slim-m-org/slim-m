---
category: Forms
---

# Toggle

An on/off switch, 40 by 22. State reads from the thumb position and the track fill together, never from colour alone, so always put a text label next to it.

## States

- `value` true is on (accent track, thumb right), false is off.
- `locked` is on and deliberately not changeable, for a cue that must not be switched off. It dims to 60% instead of using disabled colours.
- With no `onChange` it renders as a static mock and ignores presses.

## Usage

```jsx
<Toggle value={true} onChange={setEnabled} aria-label="Join and leave sounds" />
```

- Inside a settings screen use `SettingsToggleRow`, which pairs the switch with a label and description.
- Give it an `aria-label` naming the setting when no visible label is attached.
- It is controlled: pass `value` and `onChange`, it does not hold its own state.

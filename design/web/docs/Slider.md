---
category: Forms
---

# Slider

A continuous value control for volume, threshold and text scale. The default is a 4px round track with a filled portion and a thumb with a halo.

## Variants

- Default: a thin track. Use for volume and scale.
- `tall`: the microphone-meter shape, a 22px trough with a 2px position line instead of a filled portion. Pair it with `meter`.
- `meter` is a live input level from 0 to 100 drawn behind the track, independent of `value`.
- `muted` dims to 50% and swaps the fill to a neutral colour, for a mic that is off.
- `ticks` puts mono labels evenly under the track; the one nearest the thumb is picked out in accent.
- `disabled` makes it non-interactive.

## Usage

```jsx
<Slider tall min={-90} max={0} value={-48} meter={35} />
```

- `min`, `max` and `step` set the range. Without `step`, keys move by 1% of the range.
- It works uncontrolled with `defaultValue`, or controlled with `value` and `onChange`.
- In settings, put the label on the left and the current value in mono on the right above it, as Input sensitivity does.

---
category: Forms
---

# SegmentedControl

A row of 2 to 4 mutually exclusive options in a sunken trough. The selected option lifts to a raised chip with a hairline and medium weight. Selection is not accent-coloured.

## States

- `selectedIndex` picks the raised segment.
- An option with `disabled` is shown in the disabled text colour and cannot be chosen.

## Usage

```jsx
<SegmentedControl
  options={[{ label: 'Voice activity' }, { label: 'Push to talk' }]}
  selectedIndex={0}
  onSegmentSelected={setMode}
/>
```

- Use it for a small, always-visible choice. For more than about three options use `SettingsSelectRow`.
- Keep labels one or two words.
- It is controlled: update `selectedIndex` in `onSegmentSelected`.

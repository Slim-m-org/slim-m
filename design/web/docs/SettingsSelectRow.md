---
category: Settings
---

# SettingsSelectRow

A settings row for a choice among more than about three options. The label sits on the left, the current value and a chevron on the right. A press opens the picker: a dropdown at desktop widths, a sheet on a phone. Here it is just an `onClick`.

## Options

- `label` is a few words naming the setting.
- `value` is the label of the current choice.
- `unknownLabel` shows when `value` is omitted, for a choice not known yet. It must never equal a real choice's label. It defaults to "Unknown".

## Usage

```jsx
<SettingsSelectRow label="Microphone" value="Built-in audio" onClick={openPicker} />
```

- Use `SegmentedControl` for two or three always-visible options.
- Place it inside a `SettingsSectionCard`.

---
category: Settings
---

# SettingsToggleRow

One setting you turn on or off: a label and optional description on the left, a `Toggle` on the right. The text wraps rather than truncates, so a full sentence survives a phone width.

## Options

- `label` is a few words naming the setting.
- `description` is one short sentence, only when the effect is not obvious from the name. Do not state the default.
- `value` and `onChange` control the switch.
- `aria-label` names the switch itself when it should differ from the label.

## Usage

```jsx
<SettingsSectionCard title="Voice" divided>
  <SettingsToggleRow label="Even out loud sounds" value={true} onChange={setLeveling} />
</SettingsSectionCard>
```

- Place it inside a `SettingsSectionCard`.
- Use `SettingsSelectRow` instead when there are more than about three choices.

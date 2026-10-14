---
category: Settings
---

# SettingsSectionCard

The container every settings and admin screen is built from. A semibold title and optional description sit above a bordered card that holds the rows. A screen is a stack of these.

## Options

- `title` names the group. Omit it on a screen whose whole body is this one group, since a header would only repeat the app bar.
- `description` sits under the title and needs a title to appear. One short sentence.
- `divided` draws a hairline between children, for a card that is a list of rows.

## Usage

```jsx
<SettingsSectionCard title="Sounds" divided>
  <SettingsToggleRow label="Join and leave sounds" value={true} />
  <SettingsToggleRow label="Hold a key to talk" description="Hold the key to unmute." value={false} />
</SettingsSectionCard>
```

- Titles are a few words. Descriptions are one short sentence with no implementation detail.
- Fill it with `SettingsToggleRow` and `SettingsSelectRow`, or your own rows.

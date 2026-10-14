---
category: Settings
---

# SettingsLayout

The frame for personal settings, space settings and admin: a list of sections and the pane for the selected one.

## Width

Decided by the width of the nearest `SlimRoot`, at 800px (`kSettingsTwoPaneWidth`, higher than the 600px compact line because panes hold forms and prose).

- 800px and wider: a 240px nav on the left with a hairline edge, the selected row lit, and the pane on the right with its label as a 20px heading. The pane content is centred in a column up to 880px. It never renders empty: with no `activePane` the first section is selected.
- Under 800px: the nav is the whole screen (44px rows, a chevron on each, no lit row). With `showPane` the pane replaces it as its own screen: app bar with a back button and the section label as the title, no heading in the body.

`floating` draws the panel the wide form usually sits in (up to 860x720, window radius, float shadow).

## Usage

```jsx
<SlimRoot style={{ width: 900, height: 620 }}>
  <SettingsLayout
    title="Settings"
    activePane="voice"
    groups={[
      { items: [{ id: 'account', label: 'Account', icon: 'account' }, { id: 'voice', label: 'Voice and video', icon: 'mic' }] },
      { label: 'DEVICE', items: [{ id: 'devices', label: 'Devices', icon: 'devices', badge: '3' }] },
    ]}
  >
    <SettingsSectionCard title="Input">
      <SettingsToggleRow label="Hold a key to talk" value={false} />
    </SettingsSectionCard>
  </SettingsLayout>
</SlimRoot>
```

- `children` is the selected pane only; build each pane from SettingsSectionCard and its row components.
- A group `label` is an uppercase mono header with a top hairline; an unlabelled group gets a 20px gap.
- `showPane` only matters on compact; on wide it is ignored because the pane is always beside the nav.
- To preview the compact nav list, leave out `showPane` and `activePane`.

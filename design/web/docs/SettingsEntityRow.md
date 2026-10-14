---
category: Settings
---

# SettingsEntityRow

One row of a settings list: a role, a bot, an invite, a member. Headline with an optional badge, caption details underneath, icon actions at the end.

## Width

No breakpoint of its own; the headline truncates with an ellipsis as the row narrows. Under 600px the empty action slots grow from 30px to 44px so action columns stay aligned with touch-size IconButtons (pass `touch` on those).

## Usage

```jsx
<SettingsSectionCard title="Invites" divided>
  <SettingsEntityRow
    headline="slim.example/join/kx92"
    details={[<SettingsEntityDetail key="1">Created by Mara - 3 uses left</SettingsEntityDetail>]}
    actions={[<IconButton key="c" icon="copy" label="Copy link" />]}
  />
</SettingsSectionCard>
```

- `leading` is an Avatar or icon, `badge` sits after the headline (Badge `tag` for a bot, `warn` for stale).
- `details` are caption lines at 4px spacing; SettingsEntityDetail takes `tone` (`warn`, `danger`) and `wrap`.
- Pass `null` in `actions` to keep a gap where this row lacks an action other rows have.
- `onPress` makes the whole row a button and shows a pointer cursor; every row gets a sunken hover fill.
- `error` shows a persistent inline failure under the row; never raise a toast for an API failure here.
- `dense` trims vertical padding from 8px to 4px.

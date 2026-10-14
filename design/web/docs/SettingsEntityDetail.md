---
category: Settings
---

# SettingsEntityDetail

One caption line under a `SettingsEntityRow` headline: who created an invite, how many uses are left, a bot's last error.

```jsx
<SettingsEntityRow
  headline="release-bot"
  details={[
    <SettingsEntityDetail key="a">Created by Mara Lindqvist</SettingsEntityDetail>,
    <SettingsEntityDetail key="b" tone="warn">Token expires in 3 days</SettingsEntityDetail>,
  ]}
/>
```

- `tone` is `warn` or `danger` for a line that needs attention; plain lines are secondary text.
- Lines truncate; set `wrap` for one that must be read in full.

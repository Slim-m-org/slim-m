---
category: Settings
---

# SettingsNotice

A centred message that fills a settings pane when there is no form to show: a permission wall, a failed load.

## Width

No breakpoint. It centres in whatever pane it is given, with 24px padding; text wraps at the pane width on compact and wide alike.

## Usage

```jsx
<SettingsNotice icon="warning" message="Could not load the audit log." detail="Check your connection and open this pane again." />
```

- A 24px icon (info by default) in secondary ink, a body-size message, an optional caption `detail` under it.
- All secondary ink; the notice is calm, not an alert. A failure that needs a retry belongs in ErrorState.
- For an empty list inside a card use SettingsEmpty instead.

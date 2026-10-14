---
category: Surfaces
---

# ContentColumn

Centres its content and stops it growing past 720px. It is for settings and admin screens where a label and its value would otherwise sit a monitor apart. Below that width it does nothing.

## Usage

```jsx
<ContentColumn>
  <SettingsSectionCard title="Notifications">...</SettingsSectionCard>
</ContentColumn>
```

- `maxWidth` is in px and defaults to 720.

## Rules

- Use it on settings and admin pages, not on the chat view, which fills the window.

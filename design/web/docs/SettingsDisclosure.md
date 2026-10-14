---
category: Settings
---

# SettingsDisclosure

A collapsed row that opens to reveal advanced or rarely changed rows inside a settings card.

## Width

No breakpoint, except that the closed row grows to 44px under 600px so it stays a comfortable touch target.

## Usage

```jsx
<SettingsDisclosure title="Per-channel overrides" summary="3 overrides">
  <SettingsToggleRow label="#general" value={false} />
</SettingsDisclosure>
```

- A chevron (right when closed, down when open), the title in medium weight, and a caption `summary` at the end that says what is hidden.
- Starts closed; `defaultExpanded` opens it for a mock. It holds its own open state.
- The title turns primary ink on hover. Use it inside a SettingsSectionCard, never as a page-level accordion.

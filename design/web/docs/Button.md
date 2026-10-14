---
category: Core
---

# Button

A labelled action. Hairline border, 6px radius, no shadow, no hover lift; a press scales to 0.98 and a disabled button fades to 45%.

## Variants

- `primary`: the one accent action on a surface (Join call, Save, Create account). At most one per view.
- `secondary` (default): every ordinary action.
- `soft`: an accent-tinted action that reflects a state you are in (Following, Joined).
- `ghost`: the low-emphasis companion, usually Cancel next to a primary.
- `danger`: destructive actions (Leave server, Delete channel). Always pair with a confirm step.

## Sizes

`sm` 28px for dense rows and toolbars, `md` 34px everywhere else, `lg` 40px for onboarding and empty-state calls to action.

## Usage

```jsx
<div style={{ display: 'flex', gap: 'var(--space-8)', justifyContent: 'flex-end' }}>
  <Button variant="ghost" label="Cancel" />
  <Button variant="primary" label="Save changes" />
</div>
```

- `icon` takes an app icon name (`voice`, `check`, `add`); the icon sits before the label at 16px.
- `busy` swaps the label for a spinner and blocks presses; use it while a save is in flight instead of disabling.
- Labels are sentence case, a verb first, no trailing punctuation.
- For an icon-only control use `IconButton`, never a Button with an empty label.

---
category: Core
---

# Badge

A small outlined, uppercase label chip for a member role, a bot tag or a warning. It is never filled.

## Variants

- `role`: accent-outlined, for a member role such as Admin or Moderator. It is never coloured per role.
- `tag`: neutral, for a label like BOT or WEBHOOK.
- `warn`: amber, for stale-ness such as an out-of-date build.

## Usage

```jsx
<div style={{ display: 'flex', gap: 'var(--space-8)', alignItems: 'center' }}>
  <span>Mara Lindqvist</span>
  <Badge variant="role" label="Admin" />
</div>
```

- `variant` and `label` are both required. `icon` adds a small leading glyph in any variant.
- Keep the label to one short word; the chip uppercases it.
- Place it right after the name it describes, on the same baseline.
- Do not fill a badge or use it as a button.

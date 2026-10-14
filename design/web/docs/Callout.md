---
category: Surfaces
---

# Callout

A tone-coded inline banner for something the surrounding content cannot say itself, such as an expiring invite or why a control is unavailable.

## Tones

- `warn` (default): a caution, or the reason something is unavailable.
- `info`: neutral background information.
- `accent`: a positive highlight, such as a new capability.

There is no danger tone. A failed action uses ErrorState.

## Usage

```jsx
<Callout tone="warn">This invite expires in 2 hours.</Callout>
<Callout tone="info" icon="shield">Only members with Manage Server can change this.</Callout>
```

- `icon` overrides the per-tone default (warning, info, highlight).
- Keep the body to one or two plain sentences.

## Rules

- Accent is for its seven roles only; use the `accent` tone for a real highlight, not for decoration.
- Use it inline next to the content it explains, not as a page-level alert.

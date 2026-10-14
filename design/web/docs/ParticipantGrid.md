---
category: Voice
---

# ParticipantGrid

The call's tiles laid out as the app lays them out: a wrapping, centred row with 16px gaps.

## Width behaviour

- 600px and up: 240px tiles wrap and centre (the app grows tiles to fit, between 144 and 320px).
- Under 600px: two tiles across; a lone tile fills the width up to 320px.
- The grid only centres vertically if its parent has height.

## Usage

```jsx
<ParticipantGrid
  participants={[
    { name: 'Mara Lindqvist', speaking: true },
    { name: 'kiki', muted: true },
    { name: 'Jonas Berg', video: 'camera' },
  ]}
/>
```

- Each entry takes the ParticipantTile props except the sizes.
- Put the CallDock below the grid, not inside it.

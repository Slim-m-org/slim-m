---
category: Brand
---

# BrandLattice

The mark's idea at page scale: a faint dot lattice fading out from one accent square resting a half-step off its slot. A decorative backdrop for an onboarding rail. The square slides in once.

## Usage

```jsx
<div style={{ position: 'relative', width: 360, height: 420, overflow: 'hidden' }}>
  <BrandLattice width={360} height={420} />
</div>
```

- `width` and `height` are required, in px; the lattice is a function of size alone.
- The accent square sits at a fixed spot (about 126px across, 350px down), so give the panel a height above roughly 380px or the square falls outside it.
- It is decorative and hidden from assistive tech. Put real content over it, not in it.
- Use it once per surface, behind sign-in or onboarding. Do not tile it as a pattern.

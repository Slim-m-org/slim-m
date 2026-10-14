---
category: Brand
---

# BrandMark

The slim-m mark: three dots on a lattice and one rounded square that has left it. Use it as the product's logo. It is the only brand ink in the system.

## Usage

```jsx
<div style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-8)' }}>
  <BrandMark size={28} />
  <span>slim-m</span>
</div>
```

- `size` is the square side in px, 28 by default. Below 16 the dots drop and the square draws alone.
- `color` defaults to the accent. Pass a colour only for a mono treatment.
- The product name is written lowercase, `slim-m`.
- Do not recolour it per theme or add a wordmark effect.

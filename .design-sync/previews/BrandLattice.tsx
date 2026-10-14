import { BrandLattice } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Backdrop = () => (
  <div style={{ position: 'relative', width: 420, height: 420, overflow: 'hidden', background: 'var(--surface-base)' }}>
    <BrandLattice width={420} height={420} />
  </div>
);

export const Tall = () => (
  <div style={{ position: 'relative', width: 300, height: 480, overflow: 'hidden', background: 'var(--surface-base)' }}>
    <BrandLattice width={300} height={480} />
  </div>
);

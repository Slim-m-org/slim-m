import { BrandMark } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Sizes = () => (
  <div style={row}>
    <BrandMark size={12} />
    <BrandMark size={20} />
    <BrandMark size={28} />
    <BrandMark size={48} />
    <BrandMark size={96} />
  </div>
);

export const Lockup = () => (
  <div style={{ ...row, gap: 'var(--space-8)' }}>
    <BrandMark size={28} />
    <span style={{ fontSize: 18 }}>slim-m</span>
  </div>
);

export const Mono = () => (
  <div style={row}>
    <BrandMark size={40} color="var(--text-primary)" />
    <BrandMark size={40} color="var(--text-secondary)" />
  </div>
);

import { TypingDots } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const Default = () => (
  <div style={{ ...row, gap: 'var(--space-8)', color: 'var(--text-secondary)' }}>
    <TypingDots />
    <span>kiki is typing</span>
  </div>
);

export const Sizes = () => (
  <div style={row}>
    <TypingDots dotSize={4} />
    <TypingDots dotSize={5} />
    <TypingDots dotSize={8} />
  </div>
);

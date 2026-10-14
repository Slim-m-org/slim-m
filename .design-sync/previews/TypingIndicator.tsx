import { SlimRoot, TypingIndicator } from '@slim-m/design-system';

export const One = () => (
  <SlimRoot style={{ width: 760, padding: 12 }}>
    <TypingIndicator names={['Mara Lindqvist']} />
  </SlimRoot>
);

export const Several = () => (
  <SlimRoot style={{ width: 390, padding: 12 }}>
    <TypingIndicator names={['kiki', 'Jonas Berg']} />
  </SlimRoot>
);

import { SlimRoot, UnreadDivider } from '@slim-m/design-system';

export const Wide = () => (
  <SlimRoot style={{ width: 760 }}>
    <UnreadDivider />
  </SlimRoot>
);

export const Compact = () => (
  <SlimRoot style={{ width: 390 }}>
    <UnreadDivider />
  </SlimRoot>
);

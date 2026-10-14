import { SlimRoot, DayDivider } from '@slim-m/design-system';

export const Wide = () => (
  <SlimRoot style={{ width: 760 }}>
    <DayDivider label="Yesterday" />
    <DayDivider label="July 28, 2026" />
  </SlimRoot>
);

export const Compact = () => (
  <SlimRoot style={{ width: 390 }}>
    <DayDivider label="Today" />
  </SlimRoot>
);

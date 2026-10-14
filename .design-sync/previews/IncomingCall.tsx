import { IncomingCall, SlimRoot } from '@slim-m/design-system';

// Frames wider than the card render at their real width inside a scale transform so container queries still see 900.
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    <div style={{ width: 900, height: h, transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</div>
  </div>
);


export const Wide = () => 
  scaled(
    160,
  <SlimRoot style={{ width: 900, height: 160 }}>
    <IncomingCall name="Mara Lindqvist" />
  </SlimRoot>
  );
export const Compact = () => (
  <SlimRoot style={{ width: 390, height: 480 }}>
    <IncomingCall name="Mara Lindqvist" />
  </SlimRoot>
);

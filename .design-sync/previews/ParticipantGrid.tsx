import { ParticipantGrid, SlimRoot } from '@slim-m/design-system';

// Frames wider than the card render at their real width inside a scale transform so container queries still see 900.
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    <div style={{ width: 900, height: h, transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</div>
  </div>
);


const people = [
  { name: 'Mara Lindqvist', speaking: true },
  { name: 'kiki', muted: true },
  { name: 'Jonas Berg', local: true },
  { name: 'Mara Lindqvist', video: 'camera' as const, id: 'cam' },
];

export const Wide = () => 
  scaled(
    400,
  <SlimRoot style={{ width: 900 }}>
    <ParticipantGrid participants={people} />
  </SlimRoot>
  );
export const Compact = () => (
  <SlimRoot style={{ width: 390 }}>
    <ParticipantGrid participants={people} />
  </SlimRoot>
);

export const CompactAlone = () => (
  <SlimRoot style={{ width: 390 }}>
    <ParticipantGrid participants={[{ name: 'kiki', local: true }]} />
  </SlimRoot>
);

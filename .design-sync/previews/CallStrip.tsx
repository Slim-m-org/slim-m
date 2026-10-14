import { CallStrip, SlimRoot } from '@slim-m/design-system';

// Frames wider than the card render at their real width inside a scale transform so container queries still see 900.
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    <div style={{ width: 900, height: h, transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</div>
  </div>
);


export const Compact = () => (
  <SlimRoot style={{ width: 390 }}>
    <CallStrip channel="voice-lobby" duration="12:04" participants={[{ name: 'Mara Lindqvist', speaking: true }, { name: 'kiki' }]} />
  </SlimRoot>
);

export const SharingMuted = () => (
  <SlimRoot style={{ width: 390 }}>
    <CallStrip channel="movie-room" duration="1:03:27" sharing micOn={false} deafened participants={[{ name: 'Jonas Berg' }, { name: 'kiki' }]} />
  </SlimRoot>
);

export const AtTop = () => 
  scaled(
    80,
  <SlimRoot style={{ width: 900 }}>
    <CallStrip atTop channel="voice-lobby" participants={[{ name: 'Mara Lindqvist' }]} />
  </SlimRoot>
  );

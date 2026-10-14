import { ParticipantTile, SlimRoot } from '@slim-m/design-system';

// Frames wider than the card render at their real width inside a scale transform so container queries still see 900.
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    <div style={{ width: 900, height: h, transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</div>
  </div>
);


const row = { display: 'flex', gap: 16, padding: 16, flexWrap: 'wrap' } as const;

export const States = () => 
  scaled(
    200,
  <SlimRoot style={{ width: 900 }}>
    <div style={row}>
      <ParticipantTile name="Mara Lindqvist" speaking width={240} />
      <ParticipantTile name="kiki" muted width={240} />
      <ParticipantTile name="Jonas Berg" local width={240} />
    </div>
  </SlimRoot>
  );
export const Video = () => 
  scaled(
    200,
  <SlimRoot style={{ width: 900 }}>
    <div style={row}>
      <ParticipantTile name="Mara Lindqvist" video="camera" speaking width={240} />
      <ParticipantTile name="kiki" video="screen" width={240} />
    </div>
  </SlimRoot>
  );
export const Minimum = () => (
  <SlimRoot style={{ width: 390 }}>
    <div style={row}>
      <ParticipantTile name="Jonas Berg" width={144} />
      <ParticipantTile name="A very long display name that truncates" local width={144} />
    </div>
  </SlimRoot>
);

import { CallDock, SlimRoot } from '@slim-m/design-system';

// Frames wider than the card render at their real width inside a scale transform so container queries still see 900.
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    <div style={{ width: 900, height: h, transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</div>
  </div>
);


const frame = { display: 'flex', justifyContent: 'center', padding: 16 } as const;

export const Wide = () => 
  scaled(
    80,
  <SlimRoot style={{ width: 900 }}>
    <div style={frame}>
      <CallDock micOn micLevel={0.6} cameraOn showSpeaker />
    </div>
  </SlimRoot>
  );
export const WideMutedSharing = () => 
  scaled(
    80,
  <SlimRoot style={{ width: 900 }}>
    <div style={frame}>
      <CallDock micOn={false} sharing canvasOpen />
    </div>
  </SlimRoot>
  );
export const Compact = () => (
  <SlimRoot style={{ width: 390 }}>
    <div style={frame}>
      <CallDock micOn sharing />
    </div>
  </SlimRoot>
);

export const CompactStacked = () => (
  <SlimRoot style={{ width: 390 }}>
    <div style={frame}>
      <CallDock micOn cameraOn showSpeaker showSwitchCamera stacked />
    </div>
  </SlimRoot>
);

export const ListenOnly = () => 
  scaled(
    80,
  <SlimRoot style={{ width: 900 }}>
    <div style={frame}>
      <CallDock listenOnly showCanvas={false} />
    </div>
  </SlimRoot>
  );

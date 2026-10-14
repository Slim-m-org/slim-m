import { SlimRoot, VoiceJoinBar } from '@slim-m/design-system';

// Frames wider than the card render at their real width inside a scale transform so container queries still see 900.
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    <div style={{ width: 900, height: h, transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</div>
  </div>
);


const pad = { padding: 16 } as const;

export const WideEmpty = () => 
  scaled(
    130,
  <SlimRoot style={{ width: 900 }}>
    <div style={pad}>
      <VoiceJoinBar online={['Jonas Berg']} lastCall="yesterday" />
    </div>
  </SlimRoot>
  );
export const WideBusy = () => 
  scaled(
    130,
  <SlimRoot style={{ width: 900 }}>
    <div style={pad}>
      <VoiceJoinBar here={['Mara Lindqvist', 'kiki']} online={['Jonas Berg']} />
    </div>
  </SlimRoot>
  );
export const CompactEmpty = () => (
  <SlimRoot style={{ width: 390 }}>
    <div style={pad}>
      <VoiceJoinBar lastCall="yesterday" />
    </div>
  </SlimRoot>
);

export const CompactBusy = () => (
  <SlimRoot style={{ width: 390 }}>
    <div style={pad}>
      <VoiceJoinBar here={['Mara Lindqvist', 'kiki', 'Jonas Berg']} />
    </div>
  </SlimRoot>
);

export const WideError = () => 
  scaled(
    240,
  <SlimRoot style={{ width: 900 }}>
    <div style={pad}>
      <VoiceJoinBar errorMessage="Could not reach the voice server. Check your connection and try again." />
    </div>
  </SlimRoot>
  );

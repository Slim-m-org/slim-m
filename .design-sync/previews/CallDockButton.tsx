import { CallDockButton } from '@slim-m/design-system';

export const States = () => (
  <div style={{ display: 'flex', gap: 'var(--space-8)', alignItems: 'center' }}>
    <CallDockButton icon="mic" label="Mute" level={0.6} />
    <CallDockButton icon="micOff" label="Unmute" destructive />
    <CallDockButton icon="screenShare" label="Stop sharing" active />
    <CallDockButton icon="camera" label="Turn on camera" pending />
    <CallDockButton icon="micOff" label="Listen-only" unavailable />
    <CallDockButton icon="leaveCall" label="Leave call" destructive />
  </div>
);

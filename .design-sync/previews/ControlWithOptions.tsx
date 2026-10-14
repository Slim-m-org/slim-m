import { ControlWithOptions, IconButton } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

const noop = () => {};

export const Joined = () => (
  <div style={row}>
    <ControlWithOptions optionsLabel="Microphone options" onOpenOptions={noop}>
      <IconButton icon="mic" label="Mute" />
    </ControlWithOptions>
    <ControlWithOptions optionsLabel="Camera options" onOpenOptions={noop}>
      <IconButton icon="camera" label="Camera" />
    </ControlWithOptions>
  </div>
);

export const ActiveShare = () => (
  <ControlWithOptions optionsLabel="Screen share options" onOpenOptions={noop} active>
    <IconButton icon="screenShare" label="Stop sharing" active />
  </ControlWithOptions>
);

export const NoOptions = () => (
  <ControlWithOptions optionsLabel="Camera options">
    <IconButton icon="camera" label="Camera" />
  </ControlWithOptions>
);

import { Icon, type IconName } from '@slim-m/design-system';

const cell = (name: IconName) => (
  <div key={name} style={{ display: 'grid', justifyItems: 'center', gap: 'var(--space-4)', width: 132, textAlign: 'center' }}>
    <Icon name={name} size={20} />
    <span className="sm-mono" style={{ fontSize: 'var(--text-micro)', color: 'var(--text-secondary)' }}>{name}</span>
  </div>
);

const grid = { display: 'flex', flexWrap: 'wrap' as const, gap: 'var(--space-12)', maxWidth: 620 };

export const Channels = () => (
  <div style={grid}>{(['hash', 'voice', 'voiceLobby', 'roomLocked', 'restrictedChannel', 'thread', 'pin', 'canvas'] as IconName[]).map(cell)}</div>
);

export const Call = () => (
  <div style={grid}>{(['mic', 'micOff', 'headphones', 'camera', 'cameraOff', 'screenShare', 'leaveCall', 'startCall'] as IconName[]).map(cell)}</div>
);

export const Actions = () => (
  <div style={grid}>{(['add', 'search', 'send', 'reply', 'edit', 'delete', 'copy', 'moreHorizontal', 'settings', 'dismiss', 'check', 'warning'] as IconName[]).map(cell)}</div>
);

export const Sizes = () => (
  <div style={{ display: 'flex', gap: 'var(--space-16)', alignItems: 'end', color: 'var(--text-secondary)' }}>
    <Icon name="voice" size={16} />
    <Icon name="voice" size={20} />
    <Icon name="voice" size={24} color="var(--accent-text)" />
  </div>
);

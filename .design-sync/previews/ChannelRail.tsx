import { ChannelRail, SlimRoot, type RailCategory } from '@slim-m/design-system';

const categories: RailCategory[] = [
  {
    id: 'top',
    name: '',
    channels: [{ id: 'general', name: 'general', selected: true }],
  },
  {
    id: 'text',
    name: 'Text channels',
    channels: [
      { id: 'announcements', name: 'announcements', unread: true, restricted: true },
      { id: 'design-review', name: 'design-review', mentioned: true },
      { id: 'offtopic', name: 'offtopic', muted: true, unread: true },
    ],
  },
  {
    id: 'voice',
    name: 'Voice channels',
    channels: [
      { id: 'voice-lobby', name: 'voice-lobby', kind: 'voice', lobby: true },
      {
        id: 'movie-room',
        name: 'movie-room',
        kind: 'voice',
        joinMuted: true,
        userLimit: 8,
        participants: [
          { name: 'Mara Lindqvist', speaking: true },
          { name: 'kiki', muted: true },
          { name: 'Jonas Berg', screenSharing: true },
        ],
      },
    ],
  },
];

const user = { name: 'Mara Lindqvist', status: 'online' as const, statusText: 'reviewing mocks' };

// The rail fills its container, so each cell sits in a root of the window width it belongs to and a pane of the rail width.
const cell = (label: string, root: number, width: number, node: React.ReactNode) => (
  <div style={{ display: 'grid', gap: 8 }}>
    <div className="sm-label">{label}</div>
    {/* The root keeps the window width its container queries need; the wrapper crops the picture to the pane. */}
    <div style={{ width, height: 700, overflow: 'hidden' }}>
      <SlimRoot style={{ width: root, height: 700 }}>
        <div style={{ width, height: 700 }}>{node}</div>
      </SlimRoot>
    </div>
  </div>
);

export const Docked = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Expanded 1100: rail 248', 1100, 248, <ChannelRail spaceName="slim-m" categories={categories} user={user} />)}
    {cell('Medium 800: rail 240', 800, 240, <ChannelRail spaceName="slim-m" categories={categories} user={user} />)}
  </div>
);

export const InCall = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Compact 390: drawer 304', 390, 304, <ChannelRail spaceName="slim-m" categories={categories} user={{ ...user, inCall: true, micMuted: true }} updatePending />)}
  </div>
);

export const Folded = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Collapsed category', 1100, 248, <ChannelRail spaceName="slim-m" categories={categories.map((c) => (c.id === 'text' ? { ...c, collapsed: true } : c))} user={{ ...user, status: 'dnd' }} />)}
  </div>
);

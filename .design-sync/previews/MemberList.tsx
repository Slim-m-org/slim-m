import { MemberList, SlimRoot, type MemberSection } from '@slim-m/design-system';

const sections: MemberSection[] = [
  { label: 'Moderator', members: [{ id: 'm', name: 'Mara Lindqvist', status: 'online', activity: 'Reviewing mocks', activityIcon: 'playing' }] },
  {
    label: 'Online',
    members: [
      { id: 'j', name: 'Jonas Berg', status: 'away', role: 'Moderator', activity: 'Away' },
      { id: 'k', name: 'kiki', status: 'online', activity: 'Listening to Boards of Canada', activityIcon: 'listening' },
      { id: 'b', name: 'github-releases', status: 'online', bot: true },
    ],
  },
  { label: 'Offline', members: [{ id: 'o', name: 'Priya Nair', status: 'offline' }] },
];

const cell = (label: string, root: number, width: number, node: React.ReactNode) => (
  <div style={{ display: 'grid', gap: 8 }}>
    <div className="sm-label">{label}</div>
    {/* The root keeps the window width its container queries need; the wrapper crops the picture to the pane. */}
    <div style={{ width, height: 420, overflow: 'hidden' }}>
      <SlimRoot style={{ width: root, height: 420 }}>
        <div style={{ width, height: 420 }}>{node}</div>
      </SlimRoot>
    </div>
  </div>
);

export const Docked = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Expanded 1100: docked 236', 1100, 236, <MemberList sections={sections} />)}
    {cell('Selected row', 1100, 236, <MemberList sections={sections} selectedId="k" />)}
  </div>
);

export const CompactDrawer = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Compact 390: drawer 236, touch rows', 390, 236, <MemberList sections={sections} />)}
  </div>
);

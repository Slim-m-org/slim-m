import { AppShell, ChannelHeader, ChannelRail, MemberList, SlimRoot, StatusBanner } from '@slim-m/design-system';

const rail = (
  <ChannelRail
    spaceName="slim-m"
    user={{ name: 'Mara Lindqvist', status: 'online' }}
    categories={[
      { id: 't', name: 'Text channels', channels: [{ id: 'general', name: 'general', selected: true }, { id: 'announcements', name: 'announcements', unread: true }, { id: 'design-review', name: 'design-review' }] },
      { id: 'v', name: 'Voice channels', channels: [{ id: 'voice-lobby', name: 'voice-lobby', kind: 'voice', lobby: true }, { id: 'movie-room', name: 'movie-room', kind: 'voice', participants: [{ name: 'kiki', speaking: true }, { name: 'Jonas Berg' }] }] },
    ]}
  />
);

const members = (
  <MemberList
    sections={[
      { label: 'Online', members: [{ id: 'm', name: 'Mara Lindqvist', status: 'online', role: 'Moderator' }, { id: 'k', name: 'kiki', status: 'online' }] },
      { label: 'Offline', members: [{ id: 'j', name: 'Jonas Berg', status: 'offline' }] },
    ]}
  />
);

const content = (
  <div style={{ padding: 20, color: 'var(--text-secondary)' }}>
    <div style={{ color: 'var(--text-primary)', fontWeight: 500 }}>Mara Lindqvist</div>
    Pushed the new rail spec, take a look when you have a minute.
  </div>
);

const header = <ChannelHeader name="general" topic="Everything that is not somewhere else" />;

const cell = (label: string, width: number, height: number, node: React.ReactNode, scale = 1) => (
  <div style={{ display: 'grid', gap: 8 }}>
    <div className="sm-label">{label}</div>
    {/* A transform shrinks the frame for the card without changing the width its container queries see. */}
    <div style={{ width: width * scale, height: height * scale, overflow: 'hidden' }}>
      <SlimRoot style={{ border: 'var(--hairline)', width, height, transform: `scale(${scale})`, transformOrigin: '0 0' }}>{node}</SlimRoot>
    </div>
  </div>
);

const pair = (a: React.ReactNode, b: React.ReactNode) => (
  <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start' }}>
    {a}
    {b}
  </div>
);

export const Expanded = () =>
  cell('Expanded 1100 (shown at 75%): rail | content | members', 1100, 560, <AppShell rail={rail} header={header} content={content} members={members} />, 0.75);

export const Medium = () =>
  cell('Medium 800: rail | content', 800, 520, <AppShell rail={rail} header={header} content={content} members={members} />);

export const MediumMembersDrawer = () =>
  cell('Medium 800: members drawer open', 800, 520, <AppShell rail={rail} header={header} content={content} members={members} membersOpen />);

export const Compact = () =>
  pair(
    cell('Compact 390', 390, 640, <AppShell rail={rail} header={header} content={content} members={members} />),
    cell('Compact with a banner', 390, 640, <AppShell rail={rail} header={header} content={content} banner={<StatusBanner message="Reconnecting to the call." />} />),
  );

export const CompactDrawers = () =>
  pair(
    cell('Rail drawer open', 390, 640, <AppShell rail={rail} header={header} content={content} members={members} railOpen />),
    cell('Members drawer open', 390, 640, <AppShell rail={rail} header={header} content={content} members={members} membersOpen />),
  );

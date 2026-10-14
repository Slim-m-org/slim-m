import { Avatar, Icon, ListRow } from '@slim-m/design-system';

const col = { display: 'flex', flexDirection: 'column' as const, width: 260 };
const hash = <Icon name="hash" size={16} />;

export const ChannelStates = () => (
  <div style={col}>
    <ListRow label="general" leading={hash} selected />
    <ListRow label="announcements" leading={hash} unread />
    <ListRow label="design-review" leading={hash} mentioned />
    <ListRow label="off-topic" leading={hash} muted />
    <ListRow label="releases" leading={hash} />
  </div>
);

export const MemberRows = () => (
  <div style={col}>
    <ListRow label="Maya Chen" subtitle="Playing Factorio" leading={<Avatar name="Maya Chen" size={28} status="online" />} meta="2m" />
    <ListRow label="Jonas Weber" subtitle="In Voice Lobby" subtitleIcon="voice" leading={<Avatar name="Jonas Weber" size={28} status="away" />} />
  </div>
);

export const Touch = () => (
  <div style={col}>
    <ListRow touch label="Direct messages" leading={<Icon name="chat" size={16} />} unread />
    <ListRow touch label="Settings" leading={<Icon name="settings" size={16} />} />
  </div>
);

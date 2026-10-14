import { ChannelHeader, SlimRoot } from '@slim-m/design-system';

const cell = (width: number, label: string, node: React.ReactNode) => (
  <div style={{ display: 'grid', gap: 8 }}>
    <div className="sm-label">{label}</div>
    <SlimRoot style={{ width }}>{node}</SlimRoot>
  </div>
);

export const Text = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell(390, 'Compact 390', <ChannelHeader name="design-review" topic="Mocks, specs and the odd bikeshed" />)}
    {cell(800, 'Medium 800', <ChannelHeader name="design-review" topic="Mocks, specs and the odd bikeshed" searchOpen />)}
  </div>
);

export const Restricted = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell(390, 'Compact 390', <ChannelHeader name="announcements" restricted />)}
    {cell(800, 'Medium 800', <ChannelHeader name="announcements" restricted membersOpen />)}
  </div>
);

export const Voice = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell(390, 'Compact 390', <ChannelHeader name="movie-room" kind="voice" textChatToggle />)}
    {cell(800, 'Medium 800', <ChannelHeader name="movie-room" kind="voice" topic="Friday movie night" textChatToggle textChatOpen />)}
  </div>
);

export const DirectMessage = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell(390, 'Compact 390', <ChannelHeader name="Mara Lindqvist" kind="dm" />)}
    {cell(800, 'Medium 800', <ChannelHeader name="Mara Lindqvist" kind="dm" />)}
  </div>
);

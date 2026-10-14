import { MemberProfile, SlimRoot } from '@slim-m/design-system';

const compact = { width: 390, height: 470, display: 'flex', flexDirection: 'column' as const, justifyContent: 'flex-end' as const };
const scaled = (h: number, node: React.ReactNode) => (
  <div style={{ width: 810, height: h * 0.9, overflow: 'hidden' }}>
    {/* The transform keeps the 900px width the container queries see while fitting the card. */}
    <SlimRoot style={{ width: 900, height: h, padding: 24, boxSizing: 'border-box', transform: 'scale(0.9)', transformOrigin: '0 0' }}>{node}</SlimRoot>
  </div>
);

export const PopoverWide = () =>
  scaled(
    460,
    <MemberProfile
      presentation="popover"
      userId="u-mara"
      displayName="Mara Okafor"
      username="mara"
      pronouns="she/her"
      status="online"
      statusWord="online"
      about="Mostly here for the Friday game nights."
      roles={['Moderator', 'Builder']}
      joinedLabel="joined Mar 2025"
      activity={{ heading: 'Listening to', title: 'Heron', subtitle: 'Kestrel Hours' }}
      note="owes me a rematch"
    />,
  );

export const SheetCompact = () => (
  <SlimRoot style={compact}>
    <MemberProfile
      presentation="sheet"
      userId="u-jun"
      displayName="Jun"
      username="jun_t"
      accountName="Jun Tanaka"
      status="away"
      statusWord="away"
      roles={['Member']}
      joinedLabel="joined Jul 2025"
      canModerate
    />
  </SlimRoot>
);

export const InCallTogether = () =>
  scaled(
    400,
    <MemberProfile displayName="Priya" username="priya" status="online" inCallWith="Game night" ringColor="#5b8fd6" roles={['Member']} joinedLabel="joined Jan 2026" blocked />,
  );

export const Bot = () =>
  scaled(
    470,
    <MemberProfile
      userId="bot-jellyfin"
      displayName="jellyfin"
      username="jellyfin"
      isBot
      status="online"
      statusWord="online"
      roles={['Bot']}
      joinedLabel="joined Sep 2026"
      commandPrefix="!"
      commands={[
        { name: 'watch', description: 'Play a title in your current call' },
        { name: 'search', description: 'Find something in the library' },
        { name: 'queue', description: 'Show what plays next' },
        { name: 'skip', description: 'Skip the current item' },
        { name: 'stop', description: 'Stop playback' },
      ]}
    />,
  );

export const SelfAndTimedOut = () =>
  scaled(
    470,
    <div style={{ display: 'flex', gap: 24, alignItems: 'flex-start' }}>
      <MemberProfile isSelf displayName="Nick" username="nick" status="online" statusWord="online" roles={['Owner']} joinedLabel="joined Feb 2025" />
      <MemberProfile displayName="Dev" username="dev" status="offline" statusWord="offline" timedOutFor="42m" roles={['Member']} joinedLabel="joined Aug 2026" canModerate />
    </div>,
  );

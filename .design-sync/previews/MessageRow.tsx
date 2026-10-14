import { SlimRoot, MessageRow, Mention, DayDivider, UnreadDivider } from '@slim-m/design-system';

const heart = '\u{2764}\u{FE0F}';
const thumbs = '\u{1F44D}';

export const Wide = () => (
  <SlimRoot style={{ width: 760 }}>
    <DayDivider label="Today" />
    <MessageRow author="Mara Lindqvist" time="9:41a" body="Pushed the new call dock to design-review. Can someone check the spacing on the speaking ring?" reactions={[{ emoji: thumbs, count: 3, active: true }, { emoji: heart, count: 1 }]} />
    <MessageRow author="kiki" time="9:43a" grouped body="Looks right to me at 100%." />
    <MessageRow
      author="Jonas Berg"
      time="9:44a"
      replyTo={{ author: 'Mara Lindqvist', snippet: 'Pushed the new call dock to design-review.' }}
      body={<>On it, <Mention>@Mara</Mention>. The ring clips at 28px.</>}
      edited
      attachment
      hovered
    />
  </SlimRoot>
);

export const Compact = () => (
  <SlimRoot style={{ width: 390 }}>
    <UnreadDivider />
    <MessageRow author="Mara Lindqvist" time="9:41a" body="Pushed the new call dock to design-review." reactions={[{ emoji: thumbs, count: 3, active: true }]} />
    <MessageRow author="kiki" time="9:43a" grouped body="Looks right to me at 100%." />
    <MessageRow author="Jonas Berg" time="9:44a" replyTo={{ author: 'kiki', snippet: 'Looks right to me at 100%.' }} body={<>Thanks <Mention>@kiki</Mention></>} edited />
  </SlimRoot>
);

export const Bot = () => (
  <SlimRoot style={{ width: 760 }}>
    <MessageRow author="release-bot" time="10:02a" bot body="Released client 0.104.0 to the internal channel." />
  </SlimRoot>
);

export const SendStates = () => (
  <SlimRoot style={{ width: 760 }}>
    <MessageRow author="kiki" time="10:05a" status="pending" body="Checking the contrast on the light theme." />
    <MessageRow author="kiki" time="10:05a" status="failed" failureReason="Could not reach the server." body="Checking the contrast on the light theme." />
  </SlimRoot>
);

export const CompactFailed = () => (
  <SlimRoot style={{ width: 390 }}>
    <MessageRow author="kiki" time="10:05a" status="failed" failureReason="Could not reach the server." body="Checking the contrast." />
  </SlimRoot>
);

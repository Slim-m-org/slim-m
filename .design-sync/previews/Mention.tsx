import { MessageRow, Mention } from '@slim-m/design-system';

export const InMessage = () => (
  <div style={{ width: 640 }}>
    <MessageRow author="kiki" time="14:02" body={<>Can you look at the new rail, <Mention>@Mara Lindqvist</Mention>? <Mention>@Moderator</Mention> too.</>} />
  </div>
);

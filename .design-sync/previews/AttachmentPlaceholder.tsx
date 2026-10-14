import { MessageRow, AttachmentPlaceholder } from '@slim-m/design-system';

export const InMessage = () => (
  <div style={{ width: 640 }}>
    <MessageRow author="Jonas Berg" time="09:41" body="New layout for the rail" attachment={<AttachmentPlaceholder caption="screenshot · rail-v2.png · 412 KB" />} />
  </div>
);

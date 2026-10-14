import { SlimRoot, Composer } from '@slim-m/design-system';

export const WideEmpty = () => (
  <SlimRoot style={{ width: 760, paddingTop: 12 }}>
    <Composer channelName="general" />
  </SlimRoot>
);

export const WideReplyAndFiles = () => (
  <SlimRoot style={{ width: 760, paddingTop: 12 }}>
    <Composer
      channelName="design-review"
      value="Spacing fixed, pushing now."
      replyTo={{ author: 'Mara Lindqvist', snippet: 'Can someone check the spacing on the speaking ring?' }}
      attachments={[
        { name: 'ring-before-after.png', status: 'uploading', progress: 0.4, size: '2.4 MB' },
        { name: 'notes.pdf' },
        { name: 'trace.zip', status: 'failed', error: 'File is over the upload limit.' },
      ]}
    />
  </SlimRoot>
);

export const CompactEmpty = () => (
  <SlimRoot style={{ width: 390, paddingTop: 12 }}>
    <Composer channelName="general" />
  </SlimRoot>
);

export const CompactSlowMode = () => (
  <SlimRoot style={{ width: 390, paddingTop: 12 }}>
    <Composer channelName="announcements" value="One more thing" slowModeSeconds={8} />
  </SlimRoot>
);

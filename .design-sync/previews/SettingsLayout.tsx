import { SettingsLayout, SettingsSectionCard, SettingsSelectRow, SettingsToggleRow, SlimRoot, type SettingsNavGroup } from '@slim-m/design-system';

const groups: SettingsNavGroup[] = [
  {
    items: [
      { id: 'account', label: 'Account', icon: 'account' },
      { id: 'appearance', label: 'Appearance', icon: 'appearance' },
      { id: 'notifications', label: 'Notifications', icon: 'notificationsOn' },
      { id: 'voice', label: 'Voice and video', icon: 'mic' },
    ],
  },
  {
    label: 'DEVICE',
    items: [
      { id: 'devices', label: 'Devices', icon: 'devices', badge: '3' },
      { id: 'privacy', label: 'Privacy', icon: 'shield' },
    ],
  },
];

const VoicePane = () => (
  <>
    <SettingsSectionCard title="Input" description="What the call hears from you.">
      <SettingsSelectRow label="Input device" value="Blue Yeti" />
      <SettingsToggleRow label="Even out loud sounds" description="Softens sudden peaks so a laugh does not clip." value />
      <SettingsToggleRow label="Hold a key to talk" value={false} />
    </SettingsSectionCard>
    <SettingsSectionCard title="Sounds">
      <SettingsToggleRow label="Join and leave sounds" value />
    </SettingsSectionCard>
  </>
);

const scaledFrame = (w: number, h: number, scale: number, node: React.ReactNode, pad = 0) => (
  <div style={{ width: w * scale, height: h * scale, overflow: 'hidden' }}>
    {/* The transform keeps the real width the container queries see. */}
    <SlimRoot style={{ width: w, height: h, padding: pad, boxSizing: 'border-box', transform: `scale(${scale})`, transformOrigin: '0 0' }}>{node}</SlimRoot>
  </div>
);

export const Wide = () =>
  scaledFrame(900, 620, 0.9, (
    <SettingsLayout title="Settings" groups={groups} activePane="voice">
      <VoicePane />
    </SettingsLayout>
  ));

export const CompactNavList = () => (
  <SlimRoot style={{ width: 390, height: 640 }}>
    <SettingsLayout title="Settings" groups={groups} />
  </SlimRoot>
);

export const CompactPane = () => (
  <SlimRoot style={{ width: 390, height: 640 }}>
    <SettingsLayout title="Settings" groups={groups} activePane="voice" showPane>
      <VoicePane />
    </SettingsLayout>
  </SlimRoot>
);

export const Floating = () =>
  scaledFrame(960, 760, 0.85, (
    <SettingsLayout floating title="Settings" groups={groups} activePane="voice">
      <VoicePane />
    </SettingsLayout>
  ), 20);

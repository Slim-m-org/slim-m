import { SettingsSectionCard, SettingsToggleRow, SettingsSelectRow } from '@slim-m/design-system';

const wrap = { width: 380 };

export const VoiceSettings = () => (
  <div style={wrap}>
    <SettingsSectionCard title="Voice" description="How you sound and hear others." divided>
      <SettingsSelectRow label="Microphone" value="Built-in audio" />
      <SettingsToggleRow label="Even out loud sounds" value />
      <SettingsToggleRow label="Hold a key to talk" description="Hold the key to unmute." value={false} />
    </SettingsSectionCard>
  </div>
);

export const Sounds = () => (
  <div style={wrap}>
    <SettingsSectionCard title="Sounds" divided>
      <SettingsToggleRow label="Join and leave sounds" value />
      <SettingsToggleRow label="Message sounds" value={false} />
    </SettingsSectionCard>
  </div>
);

export const Untitled = () => (
  <div style={wrap}>
    <SettingsSectionCard divided>
      <SettingsToggleRow label="Automatic updates" description="On every device you use." value />
      <SettingsSelectRow label="Update channel" value="Stable" />
    </SettingsSectionCard>
  </div>
);

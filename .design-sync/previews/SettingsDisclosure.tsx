import { SettingsDisclosure, SettingsSectionCard, SettingsToggleRow, SlimRoot } from '@slim-m/design-system';

export const Closed = () => (
  <SlimRoot style={{ width: 390, padding: 16, boxSizing: 'border-box' }}>
    <SettingsSectionCard title="Notifications">
      <SettingsToggleRow label="Mentions" value />
      <SettingsDisclosure title="Per-channel overrides" summary="3 overrides" />
    </SettingsSectionCard>
  </SlimRoot>
);

export const Open = () => (
  <SlimRoot style={{ width: 600, padding: 16, boxSizing: 'border-box' }}>
    <SettingsSectionCard title="Notifications">
      <SettingsToggleRow label="Mentions" value />
      <SettingsDisclosure title="Per-channel overrides" summary="3 overrides" defaultExpanded>
        <SettingsToggleRow label="#general" description="Muted" value={false} />
        <SettingsToggleRow label="#releases" value />
      </SettingsDisclosure>
    </SettingsSectionCard>
  </SlimRoot>
);

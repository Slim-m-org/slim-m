import { SettingsNotice, SlimRoot } from '@slim-m/design-system';

export const Default = () => (
  <SlimRoot style={{ width: 390, height: 100 }}>
    <SettingsNotice message="Only admins can see invites." />
  </SlimRoot>
);

export const WithDetail = () => (
  <SlimRoot style={{ width: 600, height: 120 }}>
    <SettingsNotice icon="warning" message="Could not load the audit log." detail="Check your connection and open this pane again." />
  </SlimRoot>
);

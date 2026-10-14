import { SettingsSectionCard, SettingsEntityRow, SettingsEntityDetail } from '@slim-m/design-system';

export const Lines = () => (
  <div style={{ width: 520 }}>
    <SettingsSectionCard title="Invites">
      <SettingsEntityRow
        headline="slim.example.com/i/k3v9q2"
        details={[
          <SettingsEntityDetail key="a">Created by Mara Lindqvist</SettingsEntityDetail>,
          <SettingsEntityDetail key="b" tone="warn">Expires in 2 hours</SettingsEntityDetail>,
        ]}
      />
      <SettingsEntityRow
        headline="release-bot"
        details={[<SettingsEntityDetail key="c" tone="danger">Last delivery failed: 401 from the webhook target</SettingsEntityDetail>]}
      />
    </SettingsSectionCard>
  </div>
);

import { Avatar, Badge, IconButton, SettingsEntityDetail, SettingsEntityRow, SettingsSectionCard, SlimRoot } from '@slim-m/design-system';

const ph = (t: string) => <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--text-secondary)' }}>{t}</span>;

const actions = [<IconButton key="e" icon="edit" label="Edit" />, <IconButton key="d" icon="delete" label="Delete" variant="dangerGhost" />];

export const Bots = () => (
  <SlimRoot style={{ width: 720, padding: 16, boxSizing: 'border-box' }}>
    <SettingsSectionCard title="Bots" divided>
      <SettingsEntityRow
        leading={<Avatar name="jellyfin" shape="square" size={32} placeholder={ph('JE')} />}
        headline="jellyfin"
        badge={<Badge variant="tag" label="Bot" />}
        details={[<SettingsEntityDetail key="1">Answers to !</SettingsEntityDetail>, <SettingsEntityDetail key="2">Added by Nick, Sep 2026</SettingsEntityDetail>]}
        actions={actions}
        onPress={() => undefined}
      />
      <SettingsEntityRow
        leading={<Avatar name="uptime" shape="square" size={32} placeholder={ph('UP')} />}
        headline="uptime"
        badge={<Badge variant="warn" label="Offline" />}
        details={[<SettingsEntityDetail key="1" tone="warn">Last seen 3 days ago</SettingsEntityDetail>]}
        actions={[null, actions[1]]}
      />
    </SettingsSectionCard>
  </SlimRoot>
);

export const InvitesCompact = () => (
  <SlimRoot style={{ width: 390, padding: 16, boxSizing: 'border-box' }}>
    <SettingsSectionCard title="Invites" divided>
      <SettingsEntityRow dense headline="slim.example/join/kx92" details={[<SettingsEntityDetail key="1">Created by Mara - 3 uses left</SettingsEntityDetail>]} actions={[<IconButton key="c" icon="copy" label="Copy link" touch />]} />
      <SettingsEntityRow
        dense
        headline="slim.example/join/q7mm"
        details={[<SettingsEntityDetail key="1" tone="danger" wrap>Expired yesterday</SettingsEntityDetail>]}
        error="Could not revoke this invite."
        actions={[<IconButton key="c" icon="copy" label="Copy link" touch />]}
      />
    </SettingsSectionCard>
  </SlimRoot>
);

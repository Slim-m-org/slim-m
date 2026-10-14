import { Toast } from '@slim-m/design-system';

const col = { display: 'flex', flexDirection: 'column' as const, gap: 'var(--space-8)', width: 320 };

export const Severities = () => (
  <div style={col}>
    <Toast severity="success" message="Invite link copied" />
    <Toast severity="info" message="Switched to Voice Lobby" />
    <Toast severity="warning" message="Slow mode is on in this channel" />
  </div>
);

export const Dismissible = () => (
  <div style={col}>
    <Toast severity="success" message="Settings saved" onDismiss={() => {}} />
  </div>
);

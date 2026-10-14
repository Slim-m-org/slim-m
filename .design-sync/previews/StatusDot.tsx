import { StatusDot } from '@slim-m/design-system';

const row = { display: 'flex', gap: 'var(--space-12)', alignItems: 'center', flexWrap: 'wrap' as const };

export const States = () => (
  <div style={row}>
    <StatusDot status="online" size={16} />
    <StatusDot status="away" size={16} />
    <StatusDot status="dnd" size={16} />
    <StatusDot status="offline" size={16} />
    <StatusDot status="hidden" size={16} />
  </div>
);

export const Sizes = () => (
  <div style={row}>
    <StatusDot status="online" size={8} />
    <StatusDot status="online" size={10} />
    <StatusDot status="online" size={14} />
    <StatusDot status="online" size={20} />
  </div>
);

export const InMemberRow = () => (
  <div style={{ display: 'flex', flexDirection: 'column', gap: 'var(--space-8)' }}>
    {([['Mara Lindqvist', 'online'], ['kiki', 'away'], ['Jonas Berg', 'dnd'], ['Ola Nordin', 'offline']] as const).map(([n, s]) => (
      <div key={n} style={row}>
        <StatusDot status={s} />
        <span>{n}</span>
      </div>
    ))}
  </div>
);

import { StatusBanner, SlimRoot } from '@slim-m/design-system';

const cell = (label: string, width: number, node: React.ReactNode) => (
  <div style={{ display: 'grid', gap: 8 }}>
    <div className="sm-label">{label}</div>
    <SlimRoot style={{ width }}>{node}</SlimRoot>
  </div>
);

export const Tones = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Transient, compact 390', 390, <StatusBanner tone="transient" message="Reconnecting to the call." />)}
    {cell('Failure, medium 800', 800, <StatusBanner tone="failure" message="Could not send your message." onAction={() => {}} onDismiss={() => {}} />)}
    {cell('Info, compact 390', 390, <StatusBanner tone="info" message="A new version of slim-m is ready." actionLabel="Restart" onAction={() => {}} onDismiss={() => {}} />)}
  </div>
);

export const WithDetail = () => (
  <div style={{ display: 'flex', gap: 24, flexWrap: 'wrap', alignItems: 'flex-start' }}>
    {cell('Timeout, compact 390', 390, <StatusBanner tone="transient" icon="warning" message="You are timed out until 18:30.">Reason: spam in #general</StatusBanner>)}
    {cell('Offline, medium 800', 800, <StatusBanner tone="transient" message="You are offline. Messages will send when you reconnect." onAction={() => {}} actionLabel="Retry now" />)}
  </div>
);

import { SlimRoot, PollView } from '@slim-m/design-system';

const options = [
  { label: 'Friday', votes: 6 },
  { label: 'Monday', votes: 3 },
  { label: 'Next week', votes: 1 },
];

export const WideOpen = () => (
  <SlimRoot style={{ width: 760, padding: 12 }}>
    <PollView question="When should we ship the call dock?" options={options} yourVote={1} closesIn="Closes in 2 h." />
  </SlimRoot>
);

export const CompactOpen = () => (
  <SlimRoot style={{ width: 390, padding: 12 }}>
    <PollView question="When should we ship the call dock?" options={options} yourVote={0} closesIn="Closes in 2 h." />
  </SlimRoot>
);

export const Closed = () => (
  <SlimRoot style={{ width: 760, padding: 12 }}>
    <PollView question="Movie night pick" options={[{ label: 'Heat', votes: 2 }, { label: 'Arrival', votes: 2 }]} closed />
  </SlimRoot>
);

export const NoVotes = () => (
  <SlimRoot style={{ width: 390, padding: 12 }}>
    <PollView question="Who is joining the call?" options={[{ label: 'Me', votes: 0 }, { label: 'Not today', votes: 0 }]} />
  </SlimRoot>
);

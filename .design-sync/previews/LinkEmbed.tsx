import { SlimRoot, LinkEmbed } from '@slim-m/design-system';

export const Wide = () => (
  <SlimRoot style={{ width: 760, padding: 12 }}>
    <LinkEmbed siteName="github.com" title="Add the call dock composite to the design system" description="Ports the dock from the Flutter app with the speaking ring, the mute state and the compact bar. Closes the open design-review items for the dock." image />
  </SlimRoot>
);

export const Compact = () => (
  <SlimRoot style={{ width: 390, padding: 12 }}>
    <LinkEmbed siteName="github.com" title="Add the call dock composite to the design system" description="Ports the dock from the Flutter app with the speaking ring and the compact bar." image />
  </SlimRoot>
);

export const TextOnly = () => (
  <SlimRoot style={{ width: 390, padding: 12 }}>
    <LinkEmbed siteName="slim.example.org" title="Release notes" authorName="release-bot" />
  </SlimRoot>
);

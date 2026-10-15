// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What's-new entries from 0.106.0, in their own file because the previous
/// archive reached its line budget.
library;

import 'whats_new_content.dart';

const List<WhatsNewEntry> whatsNewArchiveEntries8 = [
  WhatsNewEntry(
    version: '0.106.0',
    headline: 'Real music while you wait, and quieter feeds',
    points: [
      WhatsNewPoint(
        'Alone in a call, the music is real now: pick lofi, jazz, electronic '
        'or ambient from the music button in the dock.',
      ),
      WhatsNewPoint(
        'Switching to a different microphone now sticks, instead of the call '
        'going back to the old one the next time you unmute.',
      ),
      WhatsNewPoint(
        'Push-to-talk can use any key: press Change and then the key you want.',
      ),
      WhatsNewPoint(
        'A channel you can read but not post in only notifies you when you '
        'are mentioned, unless you set it to all messages.',
      ),
      WhatsNewPoint('Channel settings can make an existing channel private.'),
      WhatsNewPoint(
        'Screen share has a 2160p option in place of Source, and Settings has '
        'a Troubleshooting page for the device check.',
      ),
    ],
  ),
];

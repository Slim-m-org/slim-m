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
      WhatsNewPoint(
        'On a phone, live photos send as pictures, the photo panel is a grid '
        'you swipe down to close, and menus take less room.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.107.0',
    headline: 'Big files upload, and modules can do more',
    points: [
      WhatsNewPoint(
        'Large files upload in parts and pick up where they left off if the '
        'connection drops, so a multi-gigabyte file gets through.',
      ),
      WhatsNewPoint(
        'Admins can set an attachment size limit under Retention and limits.',
      ),
      WhatsNewPoint(
        'Screen share now really sends the frame rate and quality you pick, '
        'and Voice settings has a Call stats page showing what a call sends.',
      ),
      WhatsNewPoint(
        'Your mic stays open while muted in a call, so unmuting and '
        'push-to-talk start instantly.',
      ),
      WhatsNewPoint(
        'Installing a module shows what it can do first, and modules from the '
        'official registry carry a Verified badge.',
      ),
      WhatsNewPoint(
        'Modules can reach web services you approve and run on a schedule, '
        'posting as themselves in a channel you pick.',
      ),
    ],
  ),
];

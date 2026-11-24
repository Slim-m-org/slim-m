// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What's-new entries from 0.137.0 on, in their own file because the previous
/// archive neared its line budget.
library;

import 'whats_new_content.dart';

const List<WhatsNewEntry> whatsNewArchiveEntries11 = [
  WhatsNewEntry(
    version: '0.137.0',
    headline: 'Quieter Do not disturb, safer sign-out and better search',
    points: [
      WhatsNewPoint(
        'Do not disturb now silences message and mention notifications, '
        'sounds and banners too, not only calls. Unread badges still '
        'update.',
        warn: true,
      ),
      WhatsNewPoint(
        'A DM with someone who left the Space or deleted their account '
        'shows a small badge on their picture instead of a second line.',
      ),
      WhatsNewPoint(
        'Search finds Chinese, Japanese, Korean and Thai text, and the text '
        'inside forwards, polls and embeds.',
      ),
      WhatsNewPoint(
        'Signing out of an account clears everything that account kept on '
        'this device, and switching accounts no longer mixes their '
        'notifications.',
      ),
      WhatsNewPoint(
        'A bot repost of someone you blocked stays hidden from you, the '
        'same as their own messages.',
      ),
      WhatsNewPoint(
        'Plus: a large round of fixes from the pre-1.0 audit across links, '
        'downloads, desktop notifications and updates, voice, the canvas '
        'and admin settings.',
      ),
    ],
  ),
];

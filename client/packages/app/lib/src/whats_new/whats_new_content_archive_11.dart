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
  WhatsNewEntry(
    version: '0.138.0',
    headline: 'Connect things on the canvas, and calls that hold up better',
    points: [
      WhatsNewPoint(
        'On the canvas you can draw connections between notes and shapes, '
        'and they follow when you move things around.',
      ),
      WhatsNewPoint(
        'Notes are edited right where they sit, and can have their own '
        'colour, background and Markdown.',
      ),
      WhatsNewPoint(
        'A voice channel\'s menu has Open canvas, so you can go straight to '
        'its board.',
      ),
      WhatsNewPoint(
        'A call on Windows follows your default speaker when it changes, '
        'and on Android incoming calls ring over the lock screen and use '
        'Bluetooth headsets.',
      ),
      WhatsNewPoint(
        'After a dropped connection, open channels catch up on everything '
        'they missed.',
      ),
      WhatsNewPoint(
        'Plus: the last round of fixes from the pre-1.0 audit across '
        'desktop windows, phone downloads, push and screen sharing.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.139.0',
    headline: 'Canvas channels',
    points: [
      WhatsNewPoint(
        'There is a new kind of channel next to text and voice: a canvas '
        'channel, where the board comes first and chat sits to the side. '
        'It can have its own voice call too.',
      ),
      WhatsNewPoint(
        'You can see who has a board open, with their pictures in the '
        'top bar and a line when someone arrives.',
      ),
      WhatsNewPoint(
        'The canvas on a voice channel is now a setting. New voice channels '
        'start with it off, and turning it off only hides the board.',
        warn: true,
      ),
      WhatsNewPoint(
        "A voice channel's canvas can be exported into a new canvas channel "
        'from the canvas menu.',
      ),
    ],
  ),
];

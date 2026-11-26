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
  WhatsNewEntry(
    version: '0.139.1',
    headline: 'A tidier canvas, and smaller fixes all over',
    points: [
      WhatsNewPoint(
        'Notes and text on the canvas share one short style bar: a colour '
        'button and a size.',
      ),
      WhatsNewPoint(
        'Typing a custom emoji like :name: in a note or text shows the '
        'emoji right there.',
      ),
      WhatsNewPoint(
        'One Escape takes you back to the hand tool from any tool, and the '
        'connection dots are easier to grab.',
      ),
      WhatsNewPoint(
        "You can draw on someone's shared screen in full screen too.",
      ),
      WhatsNewPoint(
        'Thread replies and quotes show mentions by name, and search shows '
        'profile pictures when you filter by person.',
      ),
      WhatsNewPoint(
        'Photo location is removed from HEIC and TIFF photos too, even with '
        'compression off.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.140.0',
    headline: 'A tidier call dock, one Captions control and better threads',
    points: [
      WhatsNewPoint(
        'The call dock keeps the everyday controls and moves the rest into '
        'More. Use Show in dock to pin one back where it fits.',
      ),
      WhatsNewPoint(
        'The call bar above your profile has mute, deafen and screen share, '
        'so you can start or stop a share without going back to the call.',
      ),
      WhatsNewPoint(
        'Captions is one control now. If the Space transcribes calls, '
        'captions just show the transcript; if it asks first, turning '
        'captions on asks everyone.',
      ),
      WhatsNewPoint(
        'Threads read like the channel: the first message has its date, '
        'replies group, and only real mentions are highlighted.',
      ),
      WhatsNewPoint(
        'Thread replies notify you after your computer wakes or reconnects, '
        'and follow the channel\'s notification setting.',
      ),
      WhatsNewPoint(
        'Custom emoji like :name: show as the emoji while you type a '
        'message or edit one.',
      ),
      WhatsNewPoint(
        'If you are in a call on another device, your other devices show '
        'you in it.',
      ),
      WhatsNewPoint(
        'On the web, staying signed in now uses a cookie that page scripts '
        'cannot read.',
      ),
    ],
  ),
];

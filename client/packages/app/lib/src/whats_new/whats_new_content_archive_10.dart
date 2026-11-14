// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What's-new entries from 0.128.0 on, in their own file because the previous
/// archive reached its line budget.
library;

import 'whats_new_content.dart';

const List<WhatsNewEntry> whatsNewArchiveEntries10 = [
  WhatsNewEntry(
    version: '0.128.0',
    headline: 'Calls that fit, transcripts, Steam and Google Play',
    points: [
      WhatsNewPoint(
        'A call fills its space: shares and cameras are laid out to cover the '
        'most room, and people without a camera move to a row of small tiles, '
        'so a camera at the end of a big call is never off screen.',
      ),
      WhatsNewPoint(
        'The microphone, camera and share menus share one layout: devices '
        'open in a list to the side, choices are buttons in a row, and '
        'settings are switches.',
      ),
      WhatsNewPoint(
        'Calls can be transcribed. A Space chooses off, on request or always, '
        'transcripts stay with the call for as long as the Space keeps them, '
        'and Ctrl+K searches them.',
        warn: true,
      ),
      WhatsNewPoint(
        'Link Steam in Connections to show the game you are playing, with a '
        'Play button for others. Games are no longer detected on your '
        'computer.',
        warn: true,
      ),
      WhatsNewPoint(
        'Android testers can install slim-m from Google Play, which then '
        'keeps it up to date.',
      ),
      WhatsNewPoint(
        'Screen sharing: you can hide your cursor, your own share has a Stop '
        'button, and on a phone two fingers move a zoomed share and a double '
        'tap zooms where you tap.',
      ),
      WhatsNewPoint(
        'Your camera choice is remembered, call history shows a call that is '
        'still going and skips drop-ins under a minute, and the call overlay '
        'shows who is talking.',
      ),
      WhatsNewPoint(
        'A server is now named by five words. You are only asked again when '
        'its identity changes.',
      ),
      WhatsNewPoint(
        'Plus: Discord linking finishes inside the app, bots share one Bots '
        'role, and a long list of smaller fixes.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.129.0',
    headline: 'Message text on Android, and a tidier profile',
    points: [
      WhatsNewPoint(
        'Android notifications can show who wrote and what they said, like '
        'on iPhone. Turn on Message text on lock screen in Notifications.',
      ),
      WhatsNewPoint(
        'Each conversation keeps its own notification, so a message in one '
        'chat no longer hides the one before it from another.',
      ),
      WhatsNewPoint(
        'Connections in your profile only link accounts now. Sharing your '
        'Spotify track or Steam game is switched on under Activity.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.130.0',
    headline: 'Voice messages, a soundboard, and names in mentions',
    points: [
      WhatsNewPoint(
        'Record a voice message with the mic button, which takes the place '
        'of Send while the message box is empty. Spaces can turn on '
        'transcripts in Space settings, under Voice.',
      ),
      WhatsNewPoint(
        'Calls have a soundboard. Admins add short clips in Space settings, '
        'and anyone in the call can play one. Turn off Soundboard sounds in '
        'Notifications to stop hearing them.',
      ),
      WhatsNewPoint(
        'A mention reads as the name people use in this Space. Hover it to '
        'see the username.',
      ),
      WhatsNewPoint(
        'On Windows, messages and calls in the background show a '
        'notification, flash the taskbar button and badge it with your '
        'unread count.',
      ),
      WhatsNewPoint(
        'Opening a search result from long ago shows it in place, with a '
        'bar to jump back to the present.',
      ),
      WhatsNewPoint(
        'Fixed "In a call on another device" showing after you left a call '
        'or reloaded, and a Linux crash when joining a call without a '
        'sound server.',
      ),
    ],
  ),
];

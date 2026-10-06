// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What's-new entries from 0.95.0, in their own file because
/// `whats_new_content.dart` is near its line budget.
library;

import 'whats_new_content.dart';

const List<WhatsNewEntry> whatsNewArchiveEntries7 = [
  WhatsNewEntry(
    version: '0.95.0',
    headline: 'The iPhone app gets ready for the App Store',
    points: [
      WhatsNewPoint(
        'The iOS app is iPhone only, and a call keeps going when you leave '
        'the app.',
      ),
      WhatsNewPoint(
        'On iPhone, the app asks before it connects to a server on your '
        'local network.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.96.0',
    headline: 'A call rings a closed iPhone, and a long list of fixes',
    points: [
      WhatsNewPoint(
        'A direct call now rings an iPhone even when slim-m is closed, on '
        'the system call screen. Answering it joins the call.',
      ),
      WhatsNewPoint(
        'A busy thread no longer keeps the app stuck offline after it '
        'reconnects.',
      ),
      WhatsNewPoint(
        'Pressing Enter twice no longer sends a message twice, and a message '
        'that fails to send keeps its attachments for the retry.',
      ),
      WhatsNewPoint(
        '@everyone, @here and a role you hold now count as a mention for the '
        'chime and the notification banner.',
      ),
      WhatsNewPoint(
        'The moderation history loads again, and resolving a report takes it '
        'out of the open queue.',
      ),
      WhatsNewPoint(
        'On desktop, the window follows a resize properly and a maximized '
        'window opens at its full size after an update.',
      ),
      WhatsNewPoint(
        'A notification for a thread reply opens the thread, the app lock '
        'covers everything under it, and reply quotes no longer show spoiler '
        'text.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.97.0',
    headline: 'Sideways video on a phone, and a camera that opens smoothly',
    points: [
      WhatsNewPoint(
        'On a phone, a screen share, a camera or a watch party shown full '
        'screen can be turned sideways to fill the screen. The rest of the '
        'app stays upright.',
      ),
      WhatsNewPoint(
        'Turning your camera on in a call no longer freezes the desktop app '
        'while the camera starts.',
      ),
      WhatsNewPoint(
        'The Linux tarball install now opens slimm links, so linking Spotify '
        'works there too.',
      ),
    ],
  ),
];

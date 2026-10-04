// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What's-new entries for 0.92.0 to 0.94.0, in their own file because
/// `whats_new_content.dart` is near its line budget.
library;

import 'whats_new_content.dart';

const List<WhatsNewEntry> whatsNewArchiveEntries6 = [
  WhatsNewEntry(
    version: '0.92.0',
    headline: 'Copy an image, a smaller update notice, and clearer Spotify',
    points: [
      WhatsNewPoint(
        'Right-click an image, or hold it on a phone, to copy it or save it.',
      ),
      WhatsNewPoint(
        'The update notice is a small Update button in the title bar. The '
        'version is in its tooltip.',
      ),
      WhatsNewPoint(
        'Linking Spotify now says what happened, and the listening box shows '
        'cover art and where it came from.',
      ),
      WhatsNewPoint(
        'Push notifications show the message text by default for your '
        'account.',
      ),
      WhatsNewPoint('The macOS app builds again; 0.91.0 had no Mac build.'),
    ],
  ),
  WhatsNewEntry(
    version: '0.93.0',
    headline: 'Moving channels, quieter phone screens, and one row per device',
    points: [
      WhatsNewPoint(
        'On desktop, hold a channel or category to lift it, and a line shows '
        'where it will land. The grips are gone. A lone channel can now be '
        'dragged into a category.',
      ),
      WhatsNewPoint(
        'The phone channel list has no grips or menu buttons and sits '
        'closer together. The Moderate sheet scrolls and keeps Remove in '
        'reach.',
      ),
      WhatsNewPoint(
        'The reply banner is slimmer, and a reply to an image shows the '
        'image. Bot answers no longer repeat your command or show "edited".',
      ),
      WhatsNewPoint(
        'Your profile photo is the control: tap it to choose a photo, browse '
        'files or remove it.',
      ),
      WhatsNewPoint(
        'The whole in-call banner takes you back to the call. On a phone, '
        'chat is an icon in the call screen\'s top bar.',
      ),
      WhatsNewPoint(
        'Devices show one row per install with honest names, and ones you '
        'have not used lately are grouped under Not used recently.',
      ),
      WhatsNewPoint(
        'Poll bars fill from the left, the reaction plus shows only on '
        'hover, and the join-muted mic icon is gone from channel rows.',
      ),
      WhatsNewPoint(
        'A slimm link now reaches the running Linux app, so linking Spotify '
        'works on desktop.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.94.0',
    headline: 'A roomier desktop call and clearer updates',
    points: [
      WhatsNewPoint(
        'On desktop, a shared screen is a centred 16:9 card with the people '
        'strip under it, and bot controls are one row of small buttons. '
        'Nothing is hidden under the dock any more.',
      ),
      WhatsNewPoint(
        'If you installed from your package manager, the update notice says '
        'to update there and shows the command. Check GitHub is a button '
        'beside it.',
      ),
      WhatsNewPoint(
        'On Linux, the small window shown while the app starts can be moved '
        'and closed.',
      ),
      WhatsNewPoint(
        'A channel you lift in the desktop list draws once, not twice.',
      ),
    ],
  ),
];

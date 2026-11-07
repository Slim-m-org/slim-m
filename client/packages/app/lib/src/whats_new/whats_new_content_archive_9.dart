// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What's-new entries from 0.122.0, in their own file because the previous
/// archive reached its line budget.
library;

import 'whats_new_content.dart';

const List<WhatsNewEntry> whatsNewArchiveEntries9 = [
  WhatsNewEntry(
    version: '0.122.0',
    headline: 'A theme store, a freer canvas, sharper shares from the start',
    points: [
      WhatsNewPoint(
        'Appearance has a theme store: export your theme, import one, or '
        'publish it for everyone in the Space, backdrop picture included. '
        'You can also set a background picture of your own.',
      ),
      WhatsNewPoint(
        'The canvas takes any colour from a picker, remembers your recent '
        'ones, and opens the call\'s chat beside it.',
      ),
      WhatsNewPoint(
        'A screen share in the web app reaches full resolution in a couple of '
        'seconds instead of about half a minute.',
      ),
      WhatsNewPoint(
        'Banners share one look: tips fade on their own, errors stay until '
        'dealt with. Long dropdowns scroll and can be searched.',
      ),
      WhatsNewPoint(
        'Emoji import has a staging step to rename or drop files first, and '
        'picking a member uses one search list with avatars everywhere.',
      ),
      WhatsNewPoint(
        'Spotify and Discord show their logos, the Spotify card shows how far '
        'into the song you are, and module levels can be hidden for yourself.',
      ),
      WhatsNewPoint(
        'Modules can turn a call into text when everyone in it agrees, with a '
        'banner while it is on.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.123.0',
    headline: 'Your own themes, favorites and call notices',
    points: [
      WhatsNewPoint(
        'Make your own theme from the Themes page, with a live preview and a '
        'contrast check that can fix what is hard to read.',
      ),
      WhatsNewPoint(
        'Add a GIF or picture to your favorites and find it again in the '
        'Favorites tab of the GIF picker.',
      ),
      WhatsNewPoint(
        'A voice channel\'s Notifications menu can tell you when a call '
        'starts, when someone joins or when someone streams.',
      ),
      WhatsNewPoint(
        'Zoom into a screen share with ctrl and the wheel or a pinch, and '
        'viewers can draw on a shared window as well as a whole screen.',
      ),
      WhatsNewPoint(
        'Turn on the call overlay in Voice settings to see who is talking '
        'over your other windows.',
      ),
      WhatsNewPoint(
        'Admins can see when the nightly backup was last checked, and get an '
        'alert when something on the server needs attention.',
      ),
      WhatsNewPoint(
        'Themes have their own page with ten new ones, modules are one short '
        'page, and settings sit where you would look for them.',
      ),
      WhatsNewPoint(
        'On iPhone you can pick AirPods, the speaker or the phone, and on '
        'Linux you show as away once the computer is left alone.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.124.0',
    headline: 'A tidier GIF picker and a round of fixes',
    points: [
      WhatsNewPoint(
        'Favorites in the GIF picker are a star next to the search box, so '
        'the picker has one row above the GIFs instead of two.',
      ),
      WhatsNewPoint(
        'Turning hold music on or off while offline now sticks once you are '
        'back, and the Space default theme is kept for each server.',
      ),
      WhatsNewPoint(
        'If a module asks to hear a call and your answer does not go '
        'through, the prompt says why.',
      ),
      WhatsNewPoint(
        'An empty canvas explains panning for the mouse or finger you are '
        'actually using.',
      ),
      WhatsNewPoint(
        'On Android, voice channel notices and server alerts show their own '
        'text instead of New message or New sign-in.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.125.0',
    headline: 'Draw on a shared screen with the canvas tools',
    points: [
      WhatsNewPoint(
        "When someone lets viewers draw on their screen, the canvas's own pen, "
        'shapes and notes mark it up, in your pen colour.',
      ),
      WhatsNewPoint(
        'On Windows, switching microphones mid-call keeps you heard, and '
        'quitting no longer crashes.',
      ),
      WhatsNewPoint(
        'Screen shares and cameras send at a much higher bitrate, so motion '
        'stays sharp; on a slower upload they still send what fits.',
      ),
      WhatsNewPoint(
        'Your own screen and camera previews pause while slim-m is not '
        'focused, which saves a lot of CPU while you share and play.',
      ),
      WhatsNewPoint(
        'The call overlay can go on the screen you pick, and Voice and screen '
        'share settings are regrouped, with sizes your screen or camera '
        'cannot reach struck out.',
      ),
      WhatsNewPoint(
        'A Close to tray setting under Desktop: turn it off and the close '
        'button quits the app.',
      ),
      WhatsNewPoint(
        'Pen colours fit on one row, with a custom colour at the end, and the '
        'mic test in Voice settings has a Stop button.',
      ),
      WhatsNewPoint(
        'Your data now lives under About slim-m; deleting your account is in '
        'Account and security.',
      ),
      WhatsNewPoint(
        'On phones, the GIF picker no longer opens the keyboard, and tapping '
        'the text box brings it back from the photo panel.',
      ),
      WhatsNewPoint(
        'Fixed: the hold music volume slider hiding behind the taskbar, a '
        'missing name and picture after waking, closing the canvas after a '
        'call joining it again, and Escape in settings after a toggle.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.126.0',
    headline: 'Android catches up',
    points: [
      WhatsNewPoint(
        'On Android, slim-m updates itself: tap Update when a new version is '
        'out and confirm in the installer.',
      ),
      WhatsNewPoint(
        'On Android, Back from the channel list no longer ends a call you are '
        'in; the app goes to the background and the call carries on.',
      ),
      WhatsNewPoint(
        'On Android, the status bar is readable on the light themes, and the '
        'mic test works on the first tap after you allow the microphone.',
      ),
      WhatsNewPoint(
        'Fixed: an old https error staying up in Connect to a Space after '
        'the address was corrected.',
      ),
    ],
  ),
];

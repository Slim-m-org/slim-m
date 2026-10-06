// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The hand-written text the what's-new sheet shows, one entry per released
/// version that has something worth telling a returning user.
///
/// Hand-written rather than parsed from `client/CHANGELOG.md`, and that is a
/// choice with a real failure mode, written down rather than hidden: nothing
/// forces a contributor to add an entry here when they cut a release, so a
/// version can ship with genuinely user-facing changes and nothing shows up.
/// The alternative was rejected on the merits, not by default. The changelog
/// is release-please's own output (conventional-commit subjects, one per
/// squashed PR) and is explicitly a generated file this project never hand
/// edits; a `fix: a restore frame with no ids must ask the feed, not be
/// applied as empty` line is accurate and useless to a person who just wants
/// to know what changed for them. Parsing it would give a sheet that always
/// appears and never says anything worth reading, which is worse than one
/// that sometimes says nothing at all because nobody wrote it yet. The
/// mitigation was naming the risk here rather than pretending automation
/// covers it: add an entry in the same PR that ships something a user would
/// notice, the way `docs/` entries already accompany a landed change in this
/// repo.
///
/// That mitigation was not enough, and the failure mode it named happened
/// exactly as written. The newest entry sat at 0.26.0 while twelve releases
/// shipped, so the sheet correctly showed nothing every time and no one could
/// tell that apart from there being nothing to say. Naming a risk is not a
/// gate, so there is one now: `whats_new_freshness_test.dart` fails when the
/// newest entry here falls too far behind the version the app reports. It
/// still cannot know whether an entry is any *good*, only that somebody
/// looked, which is the most a mechanical check can honestly claim here.
library;

import 'whats_new_content_archive.dart';
import 'whats_new_content_archive_2.dart';
import 'whats_new_content_archive_3.dart';
import 'whats_new_content_archive_4.dart';
import 'whats_new_content_archive_5.dart';
import 'whats_new_content_archive_6.dart';
import 'whats_new_content_archive_7.dart';

/// One line of an entry. [warn] renders it in the same tone a data-affecting
/// or otherwise surprising change gets elsewhere in this app (`AppCallout`'s
/// warn tone), rather than as an ordinary bullet a user could skim past.
class WhatsNewPoint {
  const WhatsNewPoint(this.body, {this.warn = false});

  final String body;
  final bool warn;
}

/// Everything shown for one released version.
class WhatsNewEntry {
  const WhatsNewEntry({
    required this.version,
    required this.headline,
    required this.points,
  });

  /// The client version this shipped in, matching `client/pubspec.yaml` at
  /// release time. Compared with [compareVersions], not string equality, so
  /// a later patch of the same line does not need its own entry to still
  /// pick this one up on the way past.
  final String version;
  final String headline;
  final List<WhatsNewPoint> points;
}

/// Every entry shipped so far, oldest first. [pendingWhatsNewEntries] keeps
/// that order; the sheet itself decides how to present it.
const List<WhatsNewEntry> whatsNewEntries = [
  ...whatsNewArchiveEntries,
  ...whatsNewArchiveEntries2,
  ...whatsNewArchiveEntries3,
  ...whatsNewArchiveEntries4,
  ...whatsNewArchiveEntries5,
  WhatsNewEntry(
    version: '0.79.0',
    headline: 'Modules that make a noise, and a safer keychain',
    points: [
      WhatsNewPoint(
        'A module can ask slim-m to play a short sound, built from the same '
        'notes the notification chimes use, so it sounds like the rest of '
        'the app. It never plays on its own: only in answer to your own tap, '
        'and you can turn module sound off entirely in settings.',
      ),
      WhatsNewPoint(
        'Code blocks can run through a self-hosted runner, and the Run '
        'button only appears for a language a runner actually named.',
      ),
      WhatsNewPoint(
        'The app notices an update while it is still open instead of waiting '
        'for a restart, a YouTube link preview says which channel it came '
        'from, and macOS and Windows keep their secrets in the system '
        'keychain rather than beside the app.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.80.0',
    headline: 'Bots, links to a single message, and modules worth building',
    points: [
      WhatsNewPoint(
        'A Space can have bots. They are their own accounts rather than a '
        'flag on yours, they are badged as bots wherever they speak, and an '
        'administrator can revoke one without touching anybody else. There '
        'is a worked example and a guide for writing your own.',
      ),
      WhatsNewPoint(
        'Copy a link to any message and follow one back, from inside the app '
        'or from a link somebody sent you elsewhere. A link to a different '
        'Space is refused rather than followed.',
      ),
      WhatsNewPoint(
        'A half-typed message survives closing the app, and a call dropped '
        'by a flaky network comes back on its own instead of waiting for you '
        'to notice and tap.',
      ),
      WhatsNewPoint(
        'Modules can draw far more: arbitrary shapes, images, gradients, '
        'text boxes you type into, a grid placed anywhere on the scene, and '
        'a screen of their own to open on. There is a music box in the '
        'marketplace built out of all of it.',
      ),
      WhatsNewPoint(
        'An administrator can issue a password reset code from a member\'s '
        'profile, and delete an account for good. Who can join now sits with '
        'the invites, and the Dock can update every module in one press.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.81.0',
    headline: 'Getting back in, and reading a gallery properly',
    points: [
      WhatsNewPoint(
        'If you are locked out, an administrator can hand you a one-time '
        'reset code and you can use it from the sign-in screen. There is no '
        'email in this, by design - recovery is somebody you already trust '
        'vouching for you, not a mailbox.',
      ),
      WhatsNewPoint(
        'A channel full of images pages through them properly rather than '
        'loading everything at once, and a long voice channel name no '
        'longer runs off the edge of the rail.',
      ),
      WhatsNewPoint(
        'The composer refuses a slash command while a file is staged, '
        'instead of quietly sending one and dropping the other.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.82.0',
    headline: 'Private channels, and a rail that tells the truth',
    points: [
      WhatsNewPoint(
        'A channel can be created private, in one step. Before this you made '
        'it, then locked it, and it was readable by everyone in between - a '
        'gap small enough to miss and large enough to matter.',
      ),
      WhatsNewPoint(
        'The member list beside a channel now shows who can actually see '
        'that channel, rather than everyone in the Space.',
      ),
      WhatsNewPoint(
        'A thread shows the message it is about at the top, so you are not '
        'reading replies to something you have to remember. Hanging up a '
        'call returns you to the channel instead of parking you on a recap.',
      ),
      WhatsNewPoint(
        'Typing indicators no longer stick after a reconnect, the GIF '
        'picker keeps its trending list for the session rather than '
        'refetching on every open, and the analytics pane folds its '
        'explanation away once you have turned it on.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.83.0',
    headline: 'Webhooks, and a pass over the small things',
    points: [
      WhatsNewPoint(
        'Another program can post into a channel through a webhook URL, '
        'without an account. A webhook is badged wherever it speaks, it can '
        'only reach the one channel it was minted for, and revoking it takes '
        'effect immediately.',
      ),
      WhatsNewPoint(
        'A channel you marked unread by hand clears when you open it, '
        'instead of keeping its dot while you sit there reading.',
      ),
      WhatsNewPoint(
        'A mention now has its own shape rather than only its own colour, so '
        'it is still a mention if you cannot separate the two hues. The '
        'member menu flips above its anchor rather than running off the '
        'bottom of the window, and dragging a channel out of a category '
        'works without the menu entry that used to be the only way.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.86.0',
    headline: 'Quiet hours, volume per person, and a tidier call',
    points: [
      WhatsNewPoint(
        'Notifications now follow a schedule you set per weekday. Outside '
        'your hours you choose what still gets through - everything, only '
        'mentions, or nothing - and you can let named people or channels '
        'past it. Snooze quiets everything until tomorrow.',
      ),
      WhatsNewPoint(
        'Right-click a person in a call, or their bubble on the canvas, for '
        'volume, mute for me, their profile and moderation in one menu. '
        'Volume is yours alone: it changes what you hear, not what anyone '
        'else does, and it holds if they leave and rejoin.',
      ),
      WhatsNewPoint(
        'A voice channel with its chat open has one header instead of two, '
        'a shared screen names its owner on hover rather than all the time, '
        'a call tile opens its card beside the tile, and bots sit in their '
        'own group at the foot of the member list.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.87.0',
    headline: 'Select a range of messages, and gifs that hold still',
    points: [
      WhatsNewPoint(
        'Shift-click a message to select everything between it and the last '
        'one you picked. The title-bar menu on desktop now offers Restart, '
        'and Update when a newer build is known.',
      ),
      WhatsNewPoint(
        'Gifs hold on their first frame until you hover them, and pause '
        'while the window is not focused. A notification for a voice '
        "channel's chat opens the chat rather than the call.",
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.88.0',
    headline:
        'Pre-muted rooms, a member list by role, and a warning for new devices',
    points: [
      WhatsNewPoint(
        'A voice channel can be set so people join muted. The member list '
        'is grouped by role, with bots and offline members below, and from '
        "someone's card you can remove them from one channel without "
        'touching the rest.',
      ),
      WhatsNewPoint(
        'A full-screen image can be shared or saved, the sidebar narrows to '
        'a compact rail instead of an icon strip, and an open web tab shows '
        'a reload pill when a newer version is out. What you have read '
        'follows you between your devices.',
      ),
      WhatsNewPoint(
        'When a device you have not used before signs in to your account, '
        'your other devices are told. A code block that hides '
        'text-direction characters is refused, since it can make code read '
        'differently from what it does.',
        warn: true,
      ),
      WhatsNewPoint(
        'Joining the official space no longer asks for a server address or '
        'a fingerprint.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.89.0',
    headline:
        'A second factor, calls that follow you, and updates that '
        'install themselves',
    points: [
      WhatsNewPoint(
        'You can add a second factor to your account: an authenticator app '
        'code on top of your password, with recovery codes for when you lose '
        'the phone. It is optional, and an administrator can clear it if you '
        'are locked out.',
      ),
      WhatsNewPoint(
        'A call no longer stops being visible when you look at something '
        'else. Video follows you to other channels in a small player you can '
        'move, on Android it keeps playing when you leave the app, and on '
        'desktop a share or a camera can be popped out into its own window. '
        'The call bar now says which channel you are in and how long you '
        'have been there, plays something quiet while you are the only one '
        'in the room, and keeps trying to rejoin for a few minutes if your '
        'connection drops rather than giving up in seconds.',
      ),
      WhatsNewPoint(
        'The canvas has a proper hand tool for panning, keyboard shortcuts '
        'for every tool, and colour, width and shape options on the tool you '
        'have selected. On a phone the tools now sit on their own row, so '
        'the eraser is no longer off the edge of the screen.',
      ),
      WhatsNewPoint(
        'slim-m can show what you are listening to on Spotify, which works '
        'even when the music is playing on your phone, and what you are '
        'playing from a short list of games. Both are off until you turn '
        'them on, both stop while you are appearing offline, and nothing '
        'outside that list of games is ever read or reported.',
      ),
      WhatsNewPoint(
        'Hovering a message shows its actions rather than hiding them behind '
        'a menu, a channel set to mentions only now stays quiet in the '
        'sidebar until you are actually mentioned, and the desktop app keeps '
        'its local copy of your messages encrypted on disk. A category in '
        'the sidebar folds when you press its header, and a role can be '
        'set to list its members apart from everyone else.',
      ),
      WhatsNewPoint(
        'The desktop app checks for a new build, makes sure it is genuinely '
        'signed before trusting it, and installs it for you, keeping the old '
        'version until the new one has started once.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.90.0',
    headline:
        'See who reacted, a channel list that follows your finger, and '
        'statuses that tell the truth',
    points: [
      WhatsNewPoint(
        'Hold a reaction to see who left it. On desktop, hovering shows the '
        'first few names and a right-click opens the full list. Anyone you '
        'have blocked is left out, the same way they are left out of the '
        'count.',
      ),
      WhatsNewPoint(
        'On a phone the channel list now follows your finger when you drag '
        'in from the left edge, and settles open or shut when you let go. '
        'The member list does the same from the right. A message also stops '
        'looking pressed once you close its menu.',
      ),
      WhatsNewPoint(
        'Your own status no longer reads "unknown". Pictures and status dots '
        'are drawn one way everywhere, initials are no longer cut off by the '
        'dot, and if you chose to appear offline the app still knows that '
        'when you open it again.',
      ),
      WhatsNewPoint(
        'iPhones that updated from an older build could show "The channel '
        'list saved on this device could not be opened." and stay that way. '
        'That is fixed, and nothing saved on the phone was lost.',
        warn: true,
      ),
      WhatsNewPoint(
        'A link to a message keeps you in its channel, a link to a channel '
        'you cannot see says so, a half-typed message survives reloading '
        'the page, the full-screen image viewer answers Escape and the arrow '
        'keys, and at tablet width the member list has its button back.',
      ),
      WhatsNewPoint(
        'Signing in to a Space with many channels is quicker, and no longer '
        'stalls on "Could not load earlier messages".',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.91.0',
    headline:
        'A shorter message menu, threads that take focus, and dialogs that '
        'stay in the window',
    points: [
      WhatsNewPoint(
        'The message menu opens with five quick reactions, then the actions '
        'you use most, with the rest under More. A thread shows as a small '
        'chip under its message, "edited" reads inline, and editing a '
        'message now says where you are and which keys do what.',
      ),
      WhatsNewPoint(
        'On Linux, dialogs, settings pickers and What\'s New were opening as '
        'separate windows. They stay inside the app again. Release notes for '
        'every version are under About.',
      ),
      WhatsNewPoint(
        'Opening a thread on desktop puts your cursor straight in its reply '
        'box. The thread pane has its own surface and an edge you can see, '
        'and starts at the top instead of the bottom.',
      ),
      WhatsNewPoint(
        'Tab indents a list in the message box, Shift+Tab takes it back, and '
        'lists show up to three levels. Escape then Tab still leaves the '
        'box.',
      ),
      WhatsNewPoint(
        'Moving channels on a phone uses a handle you hold, so scrolling '
        'never picks a channel up, and the list scrolls when you drag near '
        'the edge. Move up and Move down are in the channel menu too.',
      ),
      WhatsNewPoint(
        'Emoji lists have a search box. A custom emoji cannot take the name '
        'of a standard one, and typing :bug: turns into the emoji. '
        'Administrators can give a member or a bot a name just for this '
        'space.',
      ),
      WhatsNewPoint(
        'A module\'s scene stays a sensible size in a message, and Escape '
        'leaves full screen.',
      ),
      WhatsNewPoint(
        'Notifications now show who wrote and what they said, on every '
        'device you use. Turn it off once under Notifications if you prefer '
        'the plain alert.',
      ),
      WhatsNewPoint(
        'Usernames no longer care about capital letters, so a phone that '
        'capitalises the first letter signs you into your own account. '
        'Turning on two-factor or deleting your account now asks for your '
        'password.',
      ),
    ],
  ),
  ...whatsNewArchiveEntries6,
  ...whatsNewArchiveEntries7,
];

/// Parses a dot-separated version like `0.17.2` into its numeric segments,
/// treating anything after a `-` or `+` (a pre-release or build tag) as not
/// part of the ordering. A segment that will not parse reads as 0 rather
/// than throwing, since a malformed version must degrade to "equal", never
/// crash the check that decides whether to show anything at all.
List<int> _versionSegments(String version) {
  final core = version.split(RegExp(r'[-+]')).first;
  return core.split('.').map((part) => int.tryParse(part) ?? 0).toList();
}

/// Ordinary three-way version compare: negative if [a] precedes [b], zero if
/// equal, positive if [a] follows. Segment count differing (`0.17` against
/// `0.17.2`) treats a missing trailing segment as 0.
int compareVersions(String a, String b) {
  final left = _versionSegments(a);
  final right = _versionSegments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

/// The entries a person on [currentVersion] has not yet been shown, having
/// last seen [lastSeen] (null meaning no what's-new version has ever been
/// recorded for this install).
///
/// Every entry from after [lastSeen] up to and including [currentVersion] is
/// returned, not only the entry matching [currentVersion] exactly: someone
/// who skipped launching the app across several releases should catch up on
/// all of them at once rather than only ever seeing the latest.
///
/// [entries] defaults to [whatsNewEntries]; a test overrides it with a small
/// fixture so the filter is checked without depending on which real releases
/// happen to have an entry today.
List<WhatsNewEntry> pendingWhatsNewEntries({
  required String? lastSeen,
  required String currentVersion,
  List<WhatsNewEntry> entries = whatsNewEntries,
}) {
  return entries
      .where((entry) => compareVersions(entry.version, currentVersion) <= 0)
      .where(
        (entry) =>
            lastSeen == null || compareVersions(entry.version, lastSeen) > 0,
      )
      .toList(growable: false);
}

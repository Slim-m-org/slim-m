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
  WhatsNewEntry(
    version: '0.110.0',
    headline:
        'Several servers in one app, and calls that leave your music alone',
    points: [
      WhatsNewPoint(
        'Sign in to more than one server and switch between them from the top '
        'left. The others keep showing unread counts and live calls.',
      ),
      WhatsNewPoint(
        'On Windows, joining a call no longer turns other apps down, and '
        'Strong noise suppression now works with every microphone.',
      ),
      WhatsNewPoint(
        'Each screen share has its own volume, on the share and in the pop-out '
        'player.',
      ),
      WhatsNewPoint(
        'Settings has a search box at the top, and sounds and phone haptics '
        'cover more of a call.',
      ),
      WhatsNewPoint(
        'Pick any profile colour, and link your Discord account to show it on '
        'your profile.',
      ),
      WhatsNewPoint(
        'Admins get an audit log of every change to the server, and a locked '
        'phone no longer signs you out.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.111.0',
    headline: 'Push to talk while you play, and an inbox for what you missed',
    points: [
      WhatsNewPoint(
        'Push to talk and the mute shortcut work while a game has focus, on '
        'Linux and Windows.',
      ),
      WhatsNewPoint(
        'The inbox lists your mentions and unread channels, with mark all '
        'read.',
      ),
      WhatsNewPoint(
        'Invite links open in a browser now, and new members get a short '
        'setup they can skip.',
      ),
      WhatsNewPoint(
        'Images load faster because the server shrinks them first, and link '
        'previews can be turned off.',
      ),
      WhatsNewPoint(
        'Password fields have a show button, and bots no longer clash over '
        'the same command.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.112.0',
    headline: 'New sounds',
    points: [
      WhatsNewPoint(
        'New sounds for messages, calls, mute and deafen, so they sound like '
        'one app.',
      ),
      WhatsNewPoint(
        'A new electronic track for when you are waiting alone in a call.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.114.0',
    headline: 'Mics that stay working, one shared canvas, and editable notes',
    points: [
      WhatsNewPoint(
        'Windows mics no longer cut out when someone joins or leaves, and '
        'your chosen mic and speaker stick.',
      ),
      WhatsNewPoint(
        'Everyone sees the canvas the same way on any screen, and you can '
        'follow someone or bring everyone to you.',
      ),
      WhatsNewPoint('Canvas notes can be edited, with markdown and @mentions.'),
      WhatsNewPoint(
        'Right click someone in a call for their volume, hide their camera, '
        'or move them to another channel.',
      ),
      WhatsNewPoint(
        'Shortcuts for mute, deafen and push to talk can be changed, and '
        'downloads save straight to your Downloads folder.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.115.0',
    headline: 'Clearer calls, a calmer canvas, and a new theme',
    points: [
      WhatsNewPoint(
        'Calls hold up better on a bad connection, and a quiet hint shows '
        'when someone\'s audio is breaking up.',
      ),
      WhatsNewPoint(
        'The mic button has a menu for your device and noise suppression, '
        'and the speaker button deafens again.',
      ),
      WhatsNewPoint(
        'On the canvas, the people in the call sit in the top left, new '
        'cameras and screens show up where you\'re looking, and tiles move '
        'live for everyone.',
      ),
      WhatsNewPoint(
        'Invite a friend in two taps, set a profile colour next to your '
        'banner, and download your data from Account & devices.',
      ),
      WhatsNewPoint('Catppuccin is in Appearance as a fourth theme.'),
    ],
  ),
  WhatsNewEntry(
    version: '0.116.0',
    headline: 'Hold music you can pause, and tidier profiles',
    points: [
      WhatsNewPoint(
        'Alone in a call, a small player plays hold music with a timeline, '
        'pause and volume, and pause picks up where it left off.',
      ),
      WhatsNewPoint(
        'The call view shows a soft glimpse of the channel\'s canvas, or '
        'colour from everyone\'s profile when the board is empty.',
      ),
      WhatsNewPoint(
        'Profiles put the name below the banner and show presence once, '
        'and a banner image sits in the same row as the colours.',
      ),
      WhatsNewPoint(
        'On a phone, the canvas and music buttons sit right on the call dock.',
      ),
      WhatsNewPoint(
        'Fit view frames what is on the board, and tapping an armed canvas '
        'tool again puts it down.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.117.0',
    headline: 'Two new themes and a roomier canvas',
    points: [
      WhatsNewPoint('Soft dark and Forest join the themes in Appearance.'),
      WhatsNewPoint(
        'The canvas board is twice as big and opens on the middle at full '
        'size, with room to pan in every direction.',
      ),
      WhatsNewPoint(
        'Whoever is talking lights up their whole tile, and hold music sits '
        'right beside the call dock.',
      ),
      WhatsNewPoint(
        'A module\'s posts say which module made them, and a bot\'s form '
        'names the bot.',
      ),
      WhatsNewPoint(
        'Web tabs no longer sign each other out, and a photo that will not '
        'open says why.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.118.0',
    headline: 'Modules that react, and calmer calls',
    points: [
      WhatsNewPoint(
        'Modules can now react to messages and calls, keep their own data, '
        'and show on profiles and next to names.',
      ),
      WhatsNewPoint(
        'Changing share or camera quality while live restarts it for you, '
        'and a volume you set sticks without rejoining.',
      ),
      WhatsNewPoint(
        'Stream volume is a slider in the stream\'s menu, and a left click '
        'on someone in the lounge opens their profile.',
      ),
      WhatsNewPoint(
        'Minimising pauses video only if you ask it to, and tabbing away '
        'never does.',
      ),
      WhatsNewPoint(
        'Everyone sees overlapping call tiles stacked the same way, and '
        'hold space to pan the canvas.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.119.0',
    headline: 'Full screen canvas, search inside files, steadier calls',
    points: [
      WhatsNewPoint(
        'Sharing screen audio on Linux no longer plays the call back to '
        'everyone, and the share menu can mute the shared audio.',
      ),
      WhatsNewPoint(
        'Strong noise suppression now also takes out loud steady noise like '
        'a vacuum, and a mic that stops working can switch to another.',
      ),
      WhatsNewPoint(
        'On the canvas, F puts the focused tile full screen and Escape '
        'leaves it, a summon asks first, and holding right click opens a '
        'tool wheel with a new text tool.',
      ),
      WhatsNewPoint(
        'Search finds text inside text, code and PDF attachments, and you '
        'can remove link previews from your own messages.',
      ),
      WhatsNewPoint(
        'Phones pause your camera while the app is in the background, and '
        'Android keeps a call going with a notification.',
      ),
      WhatsNewPoint(
        'Moderators can no longer kick, ban, time out or rename someone of '
        'the same rank, and changing the two-factor rule needs two-factor '
        'on your own account.',
        warn: true,
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.119.1',
    headline: 'Voice ping, and a quicker tool wheel',
    points: [
      WhatsNewPoint(
        'A call shows your ping to the voice server, and so does hovering '
        'the connection dot next to the Space name.',
      ),
      WhatsNewPoint(
        'Who is speaking keeps showing while the app is in the background on '
        'another screen.',
      ),
      WhatsNewPoint(
        'The camera button sits beside mute and deafen at the bottom of the '
        'channel list during a call.',
      ),
      WhatsNewPoint(
        'The canvas tool wheel opens sooner, is smaller, and closes when you '
        'move away from it.',
      ),
      WhatsNewPoint(
        'On a phone, the GIF and emoji pickers sit right on the keyboard, and '
        'the app fades in from the launch screen.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.120.0',
    headline:
        'Group DMs, the strongest noise suppression, drawing on a shared screen',
    points: [
      WhatsNewPoint(
        'Start a group conversation with up to eight people from the plus '
        'on Direct messages, and a call rings everyone in it.',
      ),
      WhatsNewPoint(
        'On Linux and Windows, Strongest noise suppression takes out much '
        'more background noise, for a little more CPU.',
      ),
      WhatsNewPoint(
        'On Linux and Windows, turn on Viewers draw on my screen and people '
        'watching your share can circle or note things on your real screen.',
      ),
      WhatsNewPoint(
        'The canvas has one People here panel for following someone or '
        'bringing everyone to you.',
      ),
      WhatsNewPoint(
        'Voice settings has an Advanced row for echo cancellation, automatic '
        'gain and built-in noise suppression.',
      ),
      WhatsNewPoint(
        'On Windows, a copy you unzipped can move itself into place and '
        'update on its own from then on.',
      ),
      WhatsNewPoint(
        'On iPhone, the app icon shows how many channels are unread, and '
        'hold music plays while you wait alone in a call.',
      ),
      WhatsNewPoint(
        'Admins get a first-time setup with a guide to how many people the '
        'server can hold, and can change a bot\'s prefix.',
      ),
      WhatsNewPoint(
        'Moderators can only remove someone from a call when their highest '
        'role is above that person\'s.',
        warn: true,
      ),
    ],
  ),
];

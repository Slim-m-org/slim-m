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
        'Calls have a soundboard with a dozen starter clips. Admins add more '
        'in Space settings, and anyone in the call can play one. Turn off '
        'Soundboard sounds in Notifications to stop hearing them.',
      ),
      WhatsNewPoint(
        'A category can hold sub-categories. Right-click it and pick Create '
        'sub-category, or drag another category into it. Each has its own '
        'permissions, so people see only the part meant for them.',
      ),
      WhatsNewPoint(
        'Stamp an emoji, a GIF or a picture of your own on someone\'s '
        'shared screen with the new Stamp tool, or drop a picture file on '
        'it, if they let viewers draw. It fades after a few seconds. On the '
        'canvas, a stamp stays like any other item. A sharer can report who '
        'sent a picture for a day from Pictures on your screen.',
      ),
      WhatsNewPoint(
        'A Spotify link shows its cover, name and length, with a Play on '
        'Spotify button. On the web it plays in the chat; elsewhere it opens '
        'in Spotify. Long pages such as GitHub and Wikipedia get a preview '
        'now too.',
      ),
      WhatsNewPoint(
        'Profiles have a new card: a colour band, your status as a dot on '
        'your picture, and a Roles section. Names in the member list take '
        'the colour of their top role.',
      ),
      WhatsNewPoint(
        'Roles work as a ladder. You can only manage, kick or time out '
        'people whose top role is below yours. Each Space has an owner, who '
        'can do everything.',
      ),
      WhatsNewPoint(
        'Appearance has a theme gallery. Pick a theme, or open one in the '
        'editor to make your own.',
      ),
      WhatsNewPoint(
        'Notes moved out of your direct messages to a button next to '
        'Settings.',
      ),
      WhatsNewPoint(
        'Right-click a voice channel and pick Open chat to read its chat '
        'without joining. Voice channel chats notify you only for mentions '
        'by default.',
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
      WhatsNewPoint(
        'A channel no longer stays unread after the message you had not '
        'read yet is deleted.',
      ),
      WhatsNewPoint(
        'When two channels you had open are deleted, the app goes back to '
        'the channel list instead of flickering between them.',
      ),
      WhatsNewPoint(
        'On the web, reloading keeps you on the page you were on, and links '
        'and the back button keep working after it.',
      ),
      WhatsNewPoint(
        'When slim-m restarts to update during a call, it puts you back in '
        'the call. If it closes unexpectedly, it asks whether to rejoin.',
      ),
      WhatsNewPoint(
        'In a voice call, the chat button shows a dot when the chat has new '
        'messages.',
      ),
      WhatsNewPoint(
        'After a call reconnects, people no longer hear your microphone '
        'twice, and muting while you join is no longer lost.',
      ),
      WhatsNewPoint(
        'Voice activity sensitivity only changes your own speaking ring now. '
        'It used to hide quieter people speaking too.',
      ),
      WhatsNewPoint(
        'Losing access to the channel you have open takes you back with a '
        'notice instead of an error, and the permission grid keeps Save and '
        'the column names in view while you edit.',
      ),
      WhatsNewPoint(
        'On Windows, the call panel and drawing overlay move with your '
        'screens when a monitor is plugged in or changed during a call.',
      ),
      WhatsNewPoint(
        'Windows no longer asks to let slim-m through the firewall after '
        'an update or when you test your microphone.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.131.0',
    headline: 'View the server as a role, private categories, and keybinds',
    points: [
      WhatsNewPoint(
        'Check what a role can see: open a role in Space settings and pick '
        'View server as this role. It is read-only and shows only roles '
        'below yours.',
      ),
      WhatsNewPoint(
        'A category has a Private switch and a list of who can see it, and '
        'it warns when channels inside it keep their own permissions.',
      ),
      WhatsNewPoint(
        'Call keybinds are off until you turn them on in Settings, and on '
        'Linux they now work while slim-m is in the background.',
      ),
      WhatsNewPoint('Soundboard clips play again on desktop.'),
      WhatsNewPoint(
        'People who join a call or come online show up straight away, and '
        'members you remove leave the list at once.',
      ),
      WhatsNewPoint(
        'Do not disturb now means no rings at all. A caller sees No answer.',
      ),
      WhatsNewPoint(
        'Only the author can edit a message. Moderators can still delete it.',
      ),
      WhatsNewPoint(
        'Click an @mention to open that person\'s profile, and press Notes '
        'again to go back to where you were.',
      ),
      WhatsNewPoint(
        'Lobbies show their rooms underneath, you can pick a category when '
        'creating a channel, and Forward can post into the same channel.',
      ),
      WhatsNewPoint(
        'The canvas toolbar stays put, notes size to your drag, and the '
        'shape tool stays on so you can draw several in a row.',
      ),
    ],
  ),
];

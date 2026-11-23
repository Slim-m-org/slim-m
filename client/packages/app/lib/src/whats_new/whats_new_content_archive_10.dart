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
  WhatsNewEntry(
    version: '0.132.0',
    headline: 'One search with filters, call details, and steadier calls',
    points: [
      WhatsNewPoint(
        'Search from any channel, DM or thread opens one search with that '
        'conversation filled in. Narrow it with from:, mentions:, has:image, '
        'pinned: and dates like during:2026-11.',
      ),
      WhatsNewPoint(
        'In a call, Call details shows the call so far, what happened and the '
        'live transcript beside it. A voice channel\'s details and chat open '
        'without joining.',
      ),
      WhatsNewPoint('YouTube links play right inside the app.'),
      WhatsNewPoint(
        'Calls recover from a stalled connection on their own instead of '
        'going silent, and a call you move to another device says so.',
      ),
      WhatsNewPoint(
        'Messages, the call timer and who is in a call keep updating while '
        'slim-m is on another screen or behind other windows.',
      ),
      WhatsNewPoint(
        'On Windows, Spotify linking finishes, the firewall asks once '
        'instead of after every update, and uninstalling asks whether to '
        'remove your data.',
      ),
      WhatsNewPoint(
        'Admins can turn on detailed server logging under Debug logs, and '
        'server logs now survive restarts.',
      ),
      WhatsNewPoint(
        'The launch screen and tooltips follow your light or dark theme.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.133.0',
    headline: 'YouTube in your messages, watch parties, and a round of fixes',
    points: [
      WhatsNewPoint(
        'On Windows and Linux, YouTube links now play right in the message, '
        'and keep playing beside the chat when you scroll away.',
      ),
      WhatsNewPoint(
        'Watch YouTube together: in a call, ask the YouTube bot to play a '
        'link and everyone watches in sync.',
      ),
      WhatsNewPoint(
        'The soundboard has its own volume and mute, right in the picker '
        'and under Voice settings.',
      ),
      WhatsNewPoint(
        'Typing works again in search and the message box after you click '
        'a YouTube video on Linux.',
      ),
      WhatsNewPoint(
        'Stamps on a screen share: animated emoji move, and big GIFs and '
        'pictures place instead of doing nothing.',
      ),
      WhatsNewPoint(
        'On Windows, a pinned taskbar icon keeps working after an update '
        'instead of leaving a second one.',
      ),
      WhatsNewPoint(
        'A call\'s timeline shows "joined ×6" instead of six rows, and quick '
        'reconnects no longer count as leaving.',
      ),
      WhatsNewPoint(
        'Your camera tile says the preview is paused while the window is in '
        'the background, instead of Starting camera.',
      ),
      WhatsNewPoint(
        'When a menu action like kick, mute or delete fails, the error now '
        'stays until you dismiss it, and mentions stay marked through edits.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.133.1',
    headline: 'One sign-in form, and search that works with a phone keyboard',
    points: [
      WhatsNewPoint(
        'Signing in and creating an account are one form now. Enter your '
        'username and password; slim-m only offers to create an account '
        'when that username does not exist, so a new device no longer '
        'leaves you with a second account.',
      ),
      WhatsNewPoint('Creating an account asks for the password twice.'),
      WhatsNewPoint(
        'On a phone, search results stay above the keyboard, and the '
        'keyboard\'s search key or a drag on the results puts it away.',
      ),
      WhatsNewPoint(
        'On Android, Back closes an open menu, sheet or search instead of '
        'leaving the app.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.133.2',
    headline: 'Canvas fixes for phones and screen readers',
    points: [
      WhatsNewPoint(
        'On Android, Back with the canvas open leaves fullscreen first, '
        'then closes the canvas, instead of leaving the channel.',
      ),
      WhatsNewPoint(
        'The follow chip and the summon card sit above the canvas board, '
        'so they no longer cover a tile.',
      ),
      WhatsNewPoint(
        'On a wide window, a screen reader goes through the channel list, '
        'the conversation, the canvas and then the member list, in that '
        'order.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.134.0',
    headline: 'Games in calls, and a clearer Strongest',
    points: [
      WhatsNewPoint(
        'Modules can now put a game on the call stage, a tile on the '
        'canvas, or a panel beside the chat.',
      ),
      WhatsNewPoint(
        'Strongest noise suppression no longer makes your voice quieter '
        'than Strong does.',
      ),
      WhatsNewPoint(
        'On Linux and Windows, Settings > Troubleshooting can record a '
        '30 second sample of your raw microphone to a file.',
      ),
    ],
  ),
  WhatsNewEntry(
    version: '0.135.0',
    headline: 'Live captions, marks, and stronger noise suppression on phones',
    points: [
      WhatsNewPoint(
        'A transcribed call can show live captions and a live Transcript '
        'tab. Captions are off until you turn them on in the call dock or '
        'in Voice settings.',
      ),
      WhatsNewPoint(
        'Mark a moment in a transcribed call with the Mark button or a '
        'hotkey, and add a note. Marks are listed with the transcript '
        'after the call.',
      ),
      WhatsNewPoint(
        'A Space can turn on voice commands, so saying its wake phrase '
        'marks the moment. It is off unless an admin turns it on, and it '
        'only reads what the transcript already wrote down.',
        warn: true,
      ),
      WhatsNewPoint(
        'Settings has a Call stats page with your own talk time, pace, '
        'filler words and languages. Only you can see it.',
      ),
      WhatsNewPoint(
        'Strong noise suppression and the input gate now work on Android, '
        'iPhone and the web, not only on Linux and Windows.',
      ),
      WhatsNewPoint(
        'On Windows you can pop a screen share or camera out into its own '
        'window that stays on top, and the app starts several seconds '
        'faster.',
      ),
      WhatsNewPoint('iPhone plays soundboard clips during a call.'),
      WhatsNewPoint(
        'Bots can be installed from the Dock as connectors, limited to '
        'the permissions an admin approves, with their own commands and '
        'panels.',
      ),
      WhatsNewPoint(
        'Plus: cameras publish at the bitrate their quality promises, '
        'sharing a large screen costs less, and module text uses the app '
        'font.',
      ),
    ],
  ),
];

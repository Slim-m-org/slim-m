<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Phone tester checklist

Steps to run with a TestFlight (iOS) or Android build, written for someone who is not a developer.
`docs/BETA-TESTERS.md` is the briefing to read first, and `docs/INSTALL.md` covers getting the app on the device.

None of the paths in sections 1 to 4 has ever been confirmed on a real device, so a report on them is the first confirmation this project gets.
Do them in order and stop at the first one that misbehaves if it blocks the rest.

## What every report needs

Copy this block into each report, one per section that went wrong or right.

- Device model and OS version (Settings, General, About on iOS; Settings, About phone on Android).
- App version (Settings, then the version line at the bottom).
- What you did, in order.
- What happened, with the exact wording of any error.
- A screenshot or screen recording.
- Whether it happened again on a second try.

A "worked" report matters as much as a "broke" one.
Send reports where the owner said to, not in a chat that scrolls away.

## Before you start

You need two accounts and two devices.
Device A is the phone under test, signed in as account A.
Device B is anything else (desktop or another phone), signed in as account B.
Both accounts must be in the same community, and account A must have allowed notifications for the app.
Invites are `slimm://` links or a bare code plus the server address, never `https://`.
Voice may not connect outside the server's own network, so join Wi-Fi on the same network if a call will not connect.

## 1. Incoming call rings, and answering from the lock screen (iOS)

Setup: lock device A and leave it on the lock screen.

1. From device B, start a direct message call to account A.
2. Watch device A for ten seconds.
3. Answer from the lock screen.
4. Talk for a few seconds, then hang up from device A.

Expected: device A shows the full-screen incoming call screen or banner with B's name and rings, and answering connects audio both ways.
While the call runs, the app shows in the Dynamic Island or the green status pill.

Known: the inbound VoIP push is deliberately not wired (`docs/OPEN-QUESTIONS.md` item 3, issue #230).
So a ring with the app fully closed may not appear, and that is a known gap, not a new bug.
Report which of these you saw: full ring, a plain notification, or nothing.

Also check the other direction once.
Start a call from inside the app on device A, press the home button, wait a minute, and confirm the call is still going and audio still flows.

## 2. Lock-screen push preview (iOS and Android)

Setup: lock device A.

1. From device B, send account A a direct message with a recognisable sentence.
2. Look at device A's lock screen.

Expected: the notification names the sender and shows the sentence.
Not expected: a generic "New message" with no name or text.

If it shows "New message", report it anyway.
Two different causes look identical from outside, so also say whether the phone had been unlocked since it last restarted.

## 3. Push for a call nobody answered

Setup: lock device A and let it sleep for a minute.

1. From device B, call account A.
2. Do not answer on device A, and let the ring time out.
3. Look at device A.

Expected: a notification arrives for the missed call, and opening it lands on the direct message where the call shows as a missed call row.

Report whether the notification arrived at all, how long after the ring ended, and what it said.

## 4. Long-press menus

Do each on device A with one finger and a half-second hold, without lifting.

1. A message in a channel: hold it.
   Expected: a menu with message actions (reply, copy, react and similar) opens, and lifting the finger does not pick an item by itself.
2. A member row in the member list: hold it.
   Expected: the member's menu opens.
3. A canvas object: open the Voice Canvas, pick the Select tool, then hold an object and hold an empty spot.
   Expected: an object menu on the object and a different menu on empty space.
   With any drawing tool armed, holding should draw or place, not open a menu, and that is intended.
4. A call tile while in a call: hold a participant.
   Expected: a quick-actions menu including a volume control.

Report any hold that did nothing, opened the wrong menu, opened one and immediately closed it, or drew a stray mark on the canvas.
Also note whether the menu sat off-screen or under the keyboard.

## 5. Phone flows changed this sprint

These were mostly exercised in tests and screenshots, not on a phone.
Each item is an action, then what you should see.
If your build predates a change, the pull request number is there so you can skip that item.

### Voice and calls

- **Land back on the channel after hang-up (#1410).**
  Open a text channel, join a voice channel, then hang up.
  Expected: you land on the last text channel you were reading, not an empty screen or the voice channel.
- **Call strip above the keyboard (#1412).**
  In a call, open a text channel and tap the message box so the keyboard appears.
  Expected: the compact call strip sits above the message list and stays visible, and nothing overlaps the keyboard.
- **Call mini-player (#1439).**
  Join a call where another person is sharing their screen or has their camera on, then open a different channel.
  Expected: a small floating video card shows their screen or camera, and you can drag it to another corner.
  Its buttons are Mute or Unmute, Leave call and Hide the mini-player, and tapping the card returns you to the call.
  Not expected: the card while the keyboard is up, while you are on the call's own channel, or after you hide it until you change channel.
- **Pre-muted voice channels (#1411).**
  As an admin, open a voice channel's settings and turn on "Join muted" under Voice (the same switch is on the create channel sheet).
  Then join that channel from the phone.
  Expected: you enter already muted, the mute control shows it, and you can unmute yourself.
- **Hold music (#1440).**
  Open Settings, then Voice.
  Expected: "Play soft music while you are alone in a call" is off by default.
  Turn it on, join a call with nobody else in it, and listen.
  Expected: soft music plays on your phone only, and it stops when someone else joins or you leave.
  With the switch off, a call you are alone in stays silent.
  On an iPhone the music comes from the app's own audio engine beside the call (`HoldMusicChannel.swift`), so also check this there.
  Expected: it plays while you are alone, it stops when someone joins and their voice and your mic keep working, earpiece, speaker and Bluetooth stay as they were, and the log shows no `DarwinAudioError`.
- **Icon badge on iPhone.**
  Close the app, have another account post in two channels (and twice in one), then look at the icon.
  Expected: the badge reads 2, one per channel with a notification waiting, and a muted channel adds nothing.
  Open the app and read one channel.
  Expected: the badge drops to 1 and that channel's notification leaves the lock screen.
  Read everything on desktop and open the app on the phone.
  Expected: the badge is gone.
  A read on another device does not clear a closed phone's badge until the app next opens.

### Members and moderation

- **Member list by role (#1421).**
  Open the member list in a channel.
  Expected: members are grouped under headings with counts, such as a role name, "Online", "Offline" and "Bots", with bots and offline members below the rest.
- **Moderation sheet (#1415).**
  As a moderator, open the member list and use "Select members to moderate", tap two or three members, then tap "Moderate".
  Expected: a bottom sheet titled "2 members selected" (or your count) opens with a "Time out for..." row of durations and a "Remove" button.
  Pick a duration and confirm the members are timed out.
  If a request is refused, the reason should stay on screen rather than flash and vanish.
- **Remove from channel (#1419).**
  As a moderator, tap a member, open their card menu, and choose "Remove from #channel-name".
  Expected: a confirm dialog says they lose access to that channel and stay in the Space, and after "Remove" the channel drops out of their list.
  You can let them back in from the channel permissions.
- **Permissions grid (#1407).**
  As an admin, open a channel's permissions.
  Expected: role names stay pinned at the left while you scroll sideways, a hint shows there is more to scroll, cells are readable, and Save applies the change and shows it after reopening.

### Chat, bots and read state

- **Read state across devices (#1408).**
  Sign in on desktop and the phone as the same account, then have another account post in a channel.
  Read it on desktop and wait a few seconds.
  Expected: the phone does not buzz for that message, and its unread badge clears.
  Report it if the phone still notified after you had read it.
- **A bot's private reply (#1425).**
  Run a bot command that answers only you.
  Expected: a card above the composer reading "Only you can see this", "from" the bot's name and a "Bot" badge.
  Another account should not see it.
- **A bot button (#1433).**
  Press a button on a bot's message.
  Expected: the button shows a pending state while it waits, then the answer arrives, private or in the channel.
  If it fails you should see "That button did not work." or the bot's own reason, with retry and dismiss.

### Images

- **Share and save from the image viewer (#1427).**
  Open a photo in a channel so it goes fullscreen, then tap "Share", then tap "Save to photos".
  Expected on iPhone: Share opens the system share sheet, and the first Save asks for permission to add to your photos.
  Allow it and expect the toast "Saved to photos.", then find the image in the Photos app.
  Deny it on a second attempt and expect a message saying to allow photo access for slim-m in Settings.
  Expected on Android: the same buttons and toast, and the image shows in Photos or Gallery.
  Android may or may not show a permission prompt depending on the version, so say which you saw.

### Sign-in and account

- **Joining the official Space (#1424, #1438).**
  On a fresh install, choose "Join the official Space" on the first screen.
  Expected: you are not asked for a server address or fingerprint, and after sign-up you go straight to the first channel with no extra screen about updates.
  The automatic update choice now lives in Settings, under About, and only on desktop, so a phone should show no such switch.
- **New sign-in warning (#1432).**
  Sign the same account in on a second device.
  Expected: the first device shows a banner reading "New sign-in: ... signed in to your account at ...", with "This wasn't me" and "This was me".
  Tap "This wasn't me".
  Expected: the banner closes and Account & devices opens, where you can sign the other device out.

### Local data and upgrade

- **Upgrade keeps your history (#1444).**
  This is the check that matters most.
  On a phone that already has an older build with messages loaded and a draft typed in some channel, install the new build over it without deleting the app.
  Open the app, turn on airplane mode, and look at a channel you had open.
  Expected: old messages are still there and the draft is still in the box, with no re-login and no long blank load.
  The first launch may take a moment while the local database is encrypted.
  Report it if history or drafts were lost, if you were signed out, or if a callout says saved messages "were cleared and are downloading again from the server".
  That callout is the fallback for a lost key, and it is worth a report even though it recovers.
- **Fresh install works (#1444).**
  Delete the app, install the new build, sign in, open a few channels and send a message.
  Expected: everything loads and works normally, and it still does after you force close and reopen the app.

Not on this list: rich presence (#1453, showing what someone is listening to) is Linux desktop only, so a phone has nothing to check.

## 6. Screen share and camera (iOS)

Start a screen share from a call and keep it up for a full minute.
Expected: it keeps going, and other participants keep seeing your screen.
Not expected: "Screen Recording has stopped" within the first few seconds.

Then turn the camera toggle on in Voice Settings and join a call.
Expected: your video appears for the other participant.

## 7. Android

Android has never had a call held on it, so a first call is the test.

- Sections 2, 3, 4 and 5 apply as written.
- Section 1: incoming calls on Android arrive as a normal call notification, not the iOS call screen.
  Report whether it rang, and whether answering connected audio.
- On the first call the app should ask for microphone permission.
  Report if it never asked, or if you granted it and the other side still heard nothing.
- Background the app during a call for a minute and report whether audio continued.

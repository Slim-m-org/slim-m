# 0044 - Rich presence: what someone is listening to or playing

Status: accepted
Date: 2026-09-29

## The ask

The owner, 2026-09-28: "spotify/music integration? (same for games)".

Read as Discord-style activity: a member row and a profile card can say "Listening to X" or "Playing Y".
This record fixes the privacy model, where activity comes from, the wire shape and what the server keeps, before any source beyond the first is built.

## Privacy model

- **Opt-in, off by default.**
  Nothing is read or sent until the person switches a source on in Settings (Profile > Activity).
- **One switch per source.**
  Only listening exists today; games get their own switch later, so turning on music never turns on game detection.
  A source that is off is never started: an opted-out device does not open a D-Bus connection or scan a process list.
- **Visible only to people who can already see your presence.**
  The server resolves an activity through the same function that resolves a status (`presence::status_for`).
  It is dropped whenever the status a viewer would read is offline.
  That covers appear-offline (hidden), a closed socket, and an unknown account.
  A hidden user still sees their own activity, the same asymmetry their status has.
- **The client checks too.**
  It sends nothing while it knows the caller is hidden, and clears what it sent when they hide.
  This is a second lock.
  The client cannot always know the visibility at launch (a known gap in `presence_controller.dart`), so the server rule is the one that holds.
- **Cleared on pause, stop and quit.**
  A paused player reports nothing.
  A closed socket drops the activity because it lives on the connection.
- **Nothing is inferred silently.**
  Detecting a game from running processes is the invasive part of Discord's design, so it stays behind its own explicit switch and an allowlist (below).

## Sources compared

| Source | Credentials | Works on | Verdict |
| --- | --- | --- | --- |
| Linux MPRIS over D-Bus | none | Linux desktop, any player that exposes `org.mpris.MediaPlayer2.*` (Spotify, browsers, mpv, VLC) | First slice. Local, private, no third party. |
| Windows SMTC (`GlobalSystemMediaTransportControls`) | none | Windows 10+ desktop, any app that registers a media session | Built, see the amendment below. A runner method channel, no account. |
| macOS Now Playing | none | macOS | Not built, see the amendment below. The only supported route is scripting Music and Spotify, and it needs an owner decision first. |
| Spotify Web API | an OAuth app registered by the owner | any platform incl. phones | Built. Needs a client id at build time, which CI supplies from the `SLIMM_SPOTIFY_CLIENT_ID` repository variable; an empty value keeps it off. See the amendment below. |
| Game detection | none | desktop | Built, see the amendment below. Opt-in, allowlist only. |

Why MPRIS first: it needs no account linking and reads exactly what the person is already playing, on the machine the owner develops on.
A phone has no equivalent, which is what Spotify linking would cover later.

### MPRIS details

The client polls the session bus every five seconds and picks the first player whose `PlaybackStatus` is `Playing` and whose metadata names a title.
Polling was chosen over subscribing to `PropertiesChanged` because a few seconds of lag is fine for presence and one loop is simpler than tracking players appearing and vanishing.
The package is `dbus` (pub.dev, BSD-3-Clause, already resolved transitively at 0.7.14), which is on `deny.toml`'s allowlist.
It is imported only through a conditional import so web builds never compile it, and the source is absent (not shown dead) on other platforms.

### Game detection (the plan; "Game detection" below records what shipped)

A process-name allowlist shipped with the client, matched only when the "playing" switch is on.
The person can see the list, and nothing outside it is ever reported or logged.
Steam's local state (the `registry.vdf` "RunningAppID" key on Linux and Windows) is a cheaper, more precise signal for Steam titles and avoids scanning processes for those.
The CS2 night bot card proposes opt-in Steam presence for one game; this mechanism is what it would sit on, so Steam presence is not built twice.

## Wire shape

An optional `activity` object on presence, in both `PresenceStatus` (`GET /presence`) and the `presence.changed` frame:

- `type`: `listening` or `playing`
- `title`: at most 128 characters
- `subtitle`: optional, at most 128 characters (the artist, for music)
- `started_at`: optional, epoch milliseconds

Text with control characters or direction-changing marks is refused, not trimmed, so what viewers read is exactly what was sent.
Two routes set it: `PUT /presence/activity` and `DELETE /presence/activity`.

**Art is not in the first shape** (amended by [0056](0056-activity-art-source-and-spotify-link-feedback.md): Spotify cover URLs only, matched exactly).
When it is added it will be an attachment or a hash the server already holds, never a URL a client supplies and the server or other clients fetch.
A URL field would let one member make every other client (or the server) request an arbitrary address.
Spotify's cover URLs would be fetched by the sender's client and re-uploaded, or skipped.

## Server storage

Ephemeral only, in memory, on the sender's `PresenceTracker` entry.
No migration and nothing on disk.
It dies with the user's last connection, which also means a reconnect starts empty and the client resends.
A second device connecting does not clear it.

## Rate limits

A new traffic class, `presence_activity`: burst 6, refill one per five seconds, per account.
A skipping listener can change track every few seconds, and each accepted write fans out to every connected member.
An unchanged repeat is accepted but not re-announced.

## Core, not a bot or a module

Activity on the member row and card is core presence.
A bot can only post messages, and a module only draws what it is given, so neither can put a line on a member row.
By [0035](0035-module-or-bot.md) it is a host surface.

## What the owner must provide for Spotify

Spotify is not built here.
When it is, the owner needs to:

- register an app in the Spotify developer dashboard and choose the redirect URIs for each client platform
- hand over the client id, and the client secret if the flow needs one (the PKCE flow does not, and is preferred)
- decide whether a token lives on the device only, or on the server (which would make the server hold a third-party credential per member)
- accept Spotify's developer terms, including the quota mode an unreviewed app runs under (a small allowlisted user list until Spotify approves it)

## Follow-up cards

Windows SMTC, macOS Now Playing, Spotify linking and game detection are separate Backlog cards linked to this record.

## Amendment 2026-09-30: one seam for every source

A source is an `ActivityFeed` in `activity_feeds.dart`: a Settings switch (off by default, one per source), a platform-availability check, and a stream of what the source sees.
`ActivityPublisher` owns the privacy rules for all of them, so a new source declares itself in `activityFeedsProvider` and cannot skip them:

- a feed is opened only while its switch is on, the caller is not hidden and the platform has the source;
- hiding closes every feed, so nothing is read locally either, not only nothing sent;
- when two feeds both report something, the first in the list is what others see;
- Settings shows the activity the server last accepted, so the person can read exactly what is shared.

### Windows SMTC

`GlobalSystemMediaTransportControlsSessionManager` is read by the runner (`now_playing_smtc.cpp`) and answered over the `slimm/now_playing` method channel.
It sees the title, artist and playback status of sessions that registered with Windows (browsers, Spotify, media players).
It does not see cover art, other apps' windows, or anything while the switch is off.
The worker thread starts on the first `current` call and stops by itself fifteen seconds after the Dart side stops asking, so turning the switch off ends all reads.
The WinRT code is its own CMake library because the runner builds with exceptions off and warnings as errors.

### macOS Now Playing: decision, not built

There is no public API that reports what another app is playing.

- **`MediaRemote` (the framework behind Control Center)** is private.
  Developers report that since macOS 15.4 the `mediaremoted` daemon only serves Apple-entitled processes, so third-party calls return nothing or fail, and the workaround in use spawns the system `/usr/bin/perl` to borrow its identity.
  This comes from third-party reports, not an Apple statement: [feedback-assistant/reports#637](https://github.com/feedback-assistant/reports/issues/637), [LyricFever#94](https://github.com/aviwad/LyricFever/issues/94) and [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter), read 2026-09-30.
  Using it would put a private-API dependency that can break on any point release in a client we ship, so it is refused.
- **`MPNowPlayingInfoCenter`** is public but only describes this app's own playback, so it cannot work for this.
- **Scripting Music and Spotify** (`NSAppleScript` or ScriptingBridge) is public and supported.
  It returns the player, track, artist and state.
  It is the only acceptable route, with these costs:
  - it covers exactly those two apps, not a browser, VLC or anything else;
  - each target app triggers its own Automation consent prompt, which only appears once the switch is on;
  - the client runs in the App Sandbox (`Runner/*.entitlements`), so it needs `com.apple.security.temporary-exception.apple-events` naming both bundle ids, and `NSAppleEventsUsageDescription` in `Info.plist`;
  - a script must first check the app is running, because telling an app that is not running to do anything launches it.

**Decision: do not build it yet.**
The sandbox exception is a distribution question (store review tends to reject it) that the owner has not answered, there is no Mac here to run even one prompt, and Spotify account linking covers Spotify on a Mac without any of this.
What would be left is Apple Music alone.
One lead worth checking first: the players post public distributed notifications (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`) that would need no automation prompt.
That is from one third-party project and is untested here, including whether a sandboxed app receives them.

When the owner decides, the work is small: a `current` handler in the macOS runner answering the same `slimm/now_playing` channel the Windows source uses (`ChannelNowPlayingSource` needs no change), the entitlement, the usage string, and a row in `createNowPlayingSource`.
It must stay off by default and be closed by hiding like every other feed.

### Game detection

Its own switch (`slimm.presence.share_game`), separate from listening and off by default.
The allowlist is `gameAllowlist` in `client/packages/platform/lib/src/game_allowlist.dart`: a short starter list that ships in the client and is shown in full under the switch in Settings.
It lives in code so adding a game is a reviewed change, not a runtime setting, and there is deliberately no way for the person to add an arbitrary process yet.
A source is a probe (process names, Steam's `RunningAppID`) plus `pickRunningGame`, which returns only an allowlisted title.
A program that is not on the list is matched against nothing, stored nowhere and never logged.

- Steam's own answer wins: `registry.vdf` on Linux and macOS, `HKCU\Software\Valve\Steam` `RunningAppID` on Windows.
  An app id that is not on the list is ignored, so Steam does not widen what is reported.
- Processes come from `/proc/*/comm` on Linux (truncated to 15 characters, which the matcher allows for), `tasklist` on Windows and `ps` on macOS.
- It polls every 15 seconds, and only while the switch is on and the person is not hidden.
- What it cannot see: window titles, file names, what a game is doing, or any program off the list.
  Steam-only titles need a `steamAppId` in their entry.
- Wire kind is `playing`, title is the list's friendly name, capped like every other activity.
- When both feeds report, listening wins, since it is first in `activityFeedsProvider`.

### Spotify account linking

Built, and absent from any build that does not set `--dart-define=SLIMM_SPOTIFY_CLIENT_ID=<id>`, so nothing shows in Settings until the owner has an app.

- **Flow:** authorization code with PKCE (S256), so there is no client secret anywhere.
  The browser opens Spotify's consent page, the redirect `slimm://spotify-callback` comes back through the existing deep-link stream, and the `state` must match or nothing is linked.
- **Scope:** `user-read-currently-playing` only.
  It returns the track, its artists and whether it is playing.
  Cover art is never read or sent, and podcasts, ads and a paused player report nothing.
- **Token:** on the device, in the key store (`slimm.spotify.tokens`).
  The server never holds a third-party credential, which is also why a second device has to link on its own.
- **The switch is the link.**
  On starts the flow and only turns on when it finishes, off deletes the token.
  Spotify has no revoke call, so Settings points at spotify.com/account/apps for removing slim-m on their side.
- **Polling:** every 10 seconds, only while the switch is on and the person is not hidden.
  A rate limit pauses requests for `Retry-After` and keeps the last answer, a network failure keeps it too, and a refused refresh (link revoked) deletes the token.
- **Priority:** a local player (MPRIS, SMTC) wins over the same track via Spotify, since it is first in the feed list.
- **Limits:** an app in Spotify's development mode only works for accounts the owner adds by hand (a small cap) until Spotify approves an extension request.
  The redirect needs the `slimm` scheme registered on the platform.
  That exists on Android, iOS, macOS and Linux, but not on Windows, where the installer does not register it yet, so linking cannot finish there.

What the owner has to do:

1. Create an app at developer.spotify.com/dashboard and accept the developer terms.
2. Add the redirect URI `slimm://spotify-callback` (one URI covers every platform, because it is a custom scheme).
3. Add the testers' Spotify accounts under the app's User Management (development mode), or request a quota extension for wider use.
4. Pass the client id as `SLIMM_SPOTIFY_CLIENT_ID` when building the client (CI build steps and release workflows).
   It is an identifier, not a secret, but it is not committed.
5. Decide whether Windows needs linking, which means registering the `slimm` scheme in the installer.

## Amendment 2026-10-15: any Steam game, named by Steam

The owner, 2026-10-15: "properly handle game detection, look how other software handles it".
Discord and Steam's own friends list name whatever Steam game is running, not only titles on a list.

- When Steam says a game is running (`RunningAppID`), its name is read from that game's own install manifest, `steamapps/appmanifest_<id>.acf`, in the library folders `libraryfolders.vdf` lists.
  So any installed Steam game is named, not only the allowlisted ones.
- Steam's own runtimes and redistributables run as apps too (Proton, the Steam Linux Runtime, Steamworks redistributables) and are never reported.
- The allowlist still covers games outside Steam, matched by process name as before.
- Nothing else about the privacy model changes: it is still opt-in behind its own switch, still read fresh and thrown away, and the switch's description now says Steam games count.

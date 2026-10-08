# 0040 - Mini-player, desktop pop-out and phone picture-in-picture

Status: accepted (parts 1 and 3 built for Android, part 2 built for Linux; iOS PiP is a follow-up)
Date: 2026-09-28

## The ask

The owner, 2026-09-25: the playback-controls fix "still requires the user to unfullscreen and move to another channel to get the video to pause, maybe it's jarring because we currently don't offer a mini player or pop out view for any of the frames / windows".
Decision 2026-09-28: "Pop out window for desktop and phones, mimic discord behavior for this".

Every framed thing in the app is inline in its channel or it fills the window.
Nothing follows you when you leave the channel a call or a stream lives in.

## What Discord does

Three separate mechanisms, one per surface.

1. **In-app mini-player.**
   Leave a call or a stream you are watching and a small floating card keeps playing in a corner of the window.
   It can be dragged, it snaps to a corner, clicking it returns you to the call, and it carries a few controls.
2. **Pop Out (desktop).**
   A stream or a call can be popped into its own always-on-top OS window that survives the main window being minimised.
3. **Picture-in-picture (phones).**
   Backgrounding the app during a video call or a stream hands the video to the OS PiP window on Android and iOS.

The three are independent.
The in-app card needs no OS support, the pop-out needs a second window, and PiP needs native code on each phone OS.

## Decision

Build the three in that order, as three separate pieces of work, and share one rule about what they carry.

**What a mini-player carries is video.**
A remote screen share first, then a remote camera.
An audio-only call already has a surface that follows you: the compact voice strip on phones, and the rail's `RailCallSummary` above it.
A floating card with no picture in it would duplicate both.
Your own share is never previewed back to you.
There is no per-user "watching" state today, so the pick is the first remote publisher in roster order; a real watched-stream choice is a later refinement.

### 1. In-app mini-player (built here)

`CallMiniPlayerHost` wraps the routed pane and floats a card over it while a call is connected, has a feed, and the user is on a different channel than the call.

- It renders `VoiceController.screenShareViewFor` and `cameraViewFor`, the same view the call screen and the fullscreen route render.
  Moving between inline, mini and fullscreen is a reparent, never a second subscription or a second LiveKit connection.
- It is draggable and snaps to one of four corners, using the fling velocity so a flick throws it.
  The corner lives in `miniPlayerCornerProvider` for the session and is not persisted.
- Tapping the video returns to the call, the same navigation the voice strip's back button performs.
  The card also has mute, leave, and a hide button.
  Hide keeps the call running and hides the card until the channel changes.
- It hides while the keyboard is up.

**What it never covers.**
The host floats over the routed pane only, not the shell.
On compact widths the pane ends above the voice strip and the keyboard, so the card cannot reach either.
The composer is inside the pane, so the bottom corners rest above a reserve (`miniPlayerComposerReserve`).
On widths where the channel header is inside the pane, the top corners rest below `miniPlayerHeaderReserve`.
Tests drive every corner at phone and desktop width and assert the card's rectangle does not overlap the composer's.
It also stays off a voice channel's own page: that page offers "Switch to this call" in the middle of the pane, which no corner can clear at every width, so the card hides there and returns on the next other channel.

**Size follows width.**
The card is 192 wide below `kCompactWidth` and 272 wide above it.
Its control row uses the shared touch-target rule (44 on touch, 30 on pointer), so it is 3 buttons wide at both.
Nothing here reads the platform.

**Phones: how it relates to the strip.**
The strip stays.
It is a status surface (rule 6 of `docs/design/desktop-vs-mobile.md`: it pushes content and never overlays it) and it is the only thing that covers an audio-only call.
The mini-player is not a status: it is content the user was watching.
It appears only when there is video, and it floats above the strip rather than replacing it, so a phone in a screen-share call shows both, the card resting inside the pane and the strip below it.
Merging the two would either make the strip grow a video (a banner that overlays) or make the card carry status it has no room for.

**Which rule.**
None of the seven surfaces in the guide describes a persistent, non-modal, draggable card, so this adds rule 8 to the guide: a persistent floating view of content the user chose to watch, allowed only over the routed pane, never over composer, keyboard or a status banner, sized by width.
Rules 6 and 7 are the nearest neighbours and the reason it must not overlay a banner and must not steal focus.

### 2. Desktop pop-out window (built for Linux)

A separate OS window for a stream or share, Discord's Pop Out.

**Options for Flutter 3.47.**
- `desktop_multi_window` 0.3.1 (published 2026-08-26) creates additional windows on Windows, macOS and Linux.
  Each window is its own Flutter engine with its own isolate, so nothing in memory is shared with the main window: not a Riverpod container, not the LiveKit `Room`, not a video texture.
- `window_manager` 0.5.2 is already a dependency and controls one window (size, position, always-on-top).
  It does not create windows.
- I could not confirm a stable first-party multi-window API in Flutter 3.47.0.
  The framework has had multi-window work in progress for desktop, but this record does not depend on it; check the flutter/flutter tracker before starting the card, since a first-party API would replace the plugin.

**What was built, and why it is not the plugin.**
Flutter 3.47.0 ships first-party windowing (`_window.dart`, `_window_linux.dart`): several `FlutterView`s in one engine and one isolate.
A pop-out is a `RegularWindow` hosted through `ViewAnchor`, so it renders the same `screenShareViewFor`/`cameraViewFor` widget from the same `Room`.
There is no second subscription, no second decode and no server token route, which is why `desktop_multi_window` (second engine) was not taken.
- The gate is `isWindowingEnabled`, read from the compile-time define `FLUTTER_ENABLED_FEATURE_FLAGS`, and it is not guarded by `kDebugMode`, so a release build honours it.
- The flutter tool only sets that define on the master channel and rejects it from `--dart-define`, so `client/packages/app/linux/flutter/CMakeLists.txt` appends it to `FLUTTER_TOOL_ENVIRONMENT`.
- `popout_windowing.dart` is the one file that imports the internal API, so a framework change lands there.
- The API is marked unstable, so a Flutter upgrade can break the build; treat a bump as needing a pop-out check.
- Windows and macOS builds do not carry the flag yet, so `popOutSupportedProvider` is false there and no button shows.
- Web never offers it.
- Always-on-top is not requested: the controller exposes no such call, and on KDE the user can set "keep above" from the window menu.
- Since 2026-10-08 the window opens undecorated (`RegularWindowControllerLinux(decorated: false)`): the app draws its own drag area, resize edges and close button, and moving or resizing goes to GTK over FFI (`popout_gtk_drag.dart`). With no OS title bar, "keep above" is no longer one click away on KDE; it is still in the window's Alt+F3 menu.
- Checked on the owner's KDE Wayland box with a release build, a real LiveKit SFU and a remote camera: the window renders live video and keeps updating while the main window is minimised.

**Sharing the LiveKit track (the second-engine option, not taken).**
It is not feasible to hand the existing track to a second engine: a texture belongs to the engine that created it.
The honest options are:
- The pop-out opens its own subscribe-only LiveKit connection for the one publisher and renders that.
  This is a second subscription, which contradicts the mini-player's "no second subscription" rule, and costs a second copy of the stream's bandwidth on the SFU and the client.
  It needs a token from the server that admits a hidden, non-publishing participant, which is a server change.
- Or the main engine keeps decoding and streams frames across a platform channel.
  This is a copy per frame and is not worth it at share resolutions.
- The first is the recommendation if the owner accepts the cost.
  Nothing in the app should call it a mini-player then, because it is a different pipeline.

**Wayland and KDE (the owner's box).**
Always-on-top is a request under Wayland, not a right: compositors may ignore it, and a client cannot position its own window.
KDE Plasma honours "keep above" set by the user through the window menu and by rules, but a Flutter window asking for it is not guaranteed.
This needs a test on the real box before the card is scoped further.
X11 and Windows and macOS are not affected in the same way.

**Web.**
A browser popup (`window.open` with a size) can hold a second page, but it cannot share the tab's LiveKit room either, so it would be the same second-connection design.
Recommendation: no pop-out on web at first, and say so in the UI by not offering the button.
The browser's own picture-in-picture for a `<video>` is a separate, cheap option that needs the track attached to a video element.

### 3. Phone picture-in-picture (Android built, iOS follow-up)

**What shipped for Android.**
No plugin: `PictureInPictureBridge.kt` is about 60 lines, and `floating` and `simple_pip_mode` would each add a dependency for the same two platform calls.
Dart reports eligibility (a connected call with a remote share or camera, the mini-player's own pick) over `top.npcserver.slimm/picture_in_picture`.
Android 12 and later enter through auto-enter, earlier versions through `onUserLeaveHint`.
While the OS shows the window, `PictureInPictureGate` hides the routed app (still mounted, so state survives) and fills the view with the feed.
A hold on video interest keeps the track subscribed, because the voice canvas would otherwise cull a tile it believes is off screen.
Not built: the OS window's own remote actions (mute, hang up), which need a `RemoteAction` and a broadcast receiver.

OS PiP for video when the app is backgrounded during a call or stream.

**Android.**
`floating` 6.0.0 and `simple_pip_mode` 1.1.0 wrap `enterPictureInPictureMode`, and both are Android only.
The activity needs `android:supportsPictureInPicture="true"` and `resizeableActivity`, and the app must decide when to enter (on user-leave-hint, when a call with video is active).
The PiP window shows the whole Flutter view, resized, so the app needs a PiP-shaped layout, which is where the mini-player's card is a good candidate to render.
It has no path to a second engine, so this one does share the track for free.

**iOS.**
There is no maintained Flutter plugin for a live remote video track.
`AVPictureInPictureController` needs an `AVSampleBufferDisplayLayer` fed with the frames (iOS 15+ `AVPictureInPictureController.ContentSource` with a sample buffer layer for live video) and an active `AVAudioSession` in the playback or play-and-record category.
That means native Swift that taps the WebRTC renderer for the track, which livekit_client does not expose today.
The Runner's `Info.plist` already lists `voip` and `remote-notification` under `UIBackgroundModes`.
PiP itself needs the `audio` background mode for a stream with no call, and hygiene's iOS wiring checks read that plist, so adding the mode is a change to a gated file that has to keep them green.
It also cannot be validated on Linux or in CI; it needs a real device via TestFlight, and the iOS release path is on hold until the sprints finish.

**Compact width and the strip.**
Once the app is backgrounded there is no in-app layout to reconcile, so the strip and PiP never show together.

## Sequence

1. In-app mini-player (this PR).
   Pure Flutter, every platform, no new dependency.
2. Android PiP.
   Smallest native surface, shares the track, and gives the owner's phone the behaviour first.
3. Desktop pop-out, gated on two owner answers: a Wayland always-on-top test on the KDE box, and whether a second subscribe-only connection is acceptable.
4. iOS PiP, last: native sample-buffer work, a gated plist change, device-only validation.

Follow-up cards: desktop pop-out window, and phone picture-in-picture (Android first, iOS after).

## Not decided here

- A real "watched stream" selection, so the mini-player carries the share the user picked rather than the first one.
- Carrying module scenes and the watch-party video, which the source card names.
  Both render through the call view today, so they arrive with the same feed once they publish a track; if a module scene is not a track it needs its own reparent story and a separate card.

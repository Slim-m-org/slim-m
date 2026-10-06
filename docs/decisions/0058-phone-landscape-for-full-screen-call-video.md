# 0058 - A phone may rotate only while a call's video is full screen

Status: accepted, 2026-10-06.

## The problem

Phones are locked to portrait on both platforms, and the hygiene workflow gates the lock.
The lock is a layout guard: the shell is width-driven, and a phone in landscape reports about 932pt, which `LayoutClass.fromWidth` classes as the two-pane medium layout and stretches a phone-sized shell across it.
It was never a decision against watching video sideways, but it had that effect: a friend's screen share, a camera, or a watch party could not be turned to fill a phone.

The owner asked for it twice (backlog #210, then on 2026-10-06: "what if a friend is streaming there desktop on mobile? no way to rotate and get a better view?").

## Decision

The shell stays portrait on phones.
`FullscreenVideoView` (`client/packages/app/lib/src/widgets/fullscreen_video_overlay.dart`), the one route that shows a call's camera or screen share full screen, asks to rotate while it is up and gives the lock back when it closes, by any path: the close control, Escape, the back gesture, or the feed ending.
The watch party is a screen share, so it goes through the same view.
Canvas landscape is out of scope.

The lock stays native, behind `OrientationChannel` (`packages/platform`, channel `top.npcserver.slimm/orientation`), rather than `SystemChrome`:

- Android: `MainActivity.allowLandscape` switches a phone between `SCREEN_ORIENTATION_PORTRAIT` and `SCREEN_ORIENTATION_SENSOR`. A tablet (`R.bool.slimm_portrait_only` false under sw600dp) is never locked, so it answers false and nothing changes. A Dart restore could not tell those two apart and would lock a tablet.
- iOS: the plist's iPhone array lists landscape, but only as the ceiling. `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` returns `.portrait` unless `landscapeAllowed` is set by the channel, so the app launches and stays portrait. iOS 16 and later re-read the mask through `setNeedsUpdateOfSupportedInterfaceOrientations` and return to portrait with `requestGeometryUpdate`; iOS 15 uses `attemptRotationToDeviceOrientation`.

The routed app never sees landscape.
Once the native side reports a locked phone, `portraitLockedPhoneProvider` is set, and `keepPortraitShell` in `appChromeBuilder` swaps a landscape window's width and height back before the routed tree reads them, so the shell keeps its portrait layout even while it sits below the full screen route.
The full screen route rebuilds its `MediaQuery` from `View.of(context)`, so it alone sees the real window: in landscape the video fills it edge to edge and a tap shows or hides the name line and close control.
Nothing needs clearing on close, so the shell is never caught mid-rotation at the wide size.

## The gate

The hygiene step "orientation is locked on phones only" still fails on landscape in the iPhone array, unless `AppDelegate.swift` (comments stripped) still defaults to portrait and `fullscreen_video_overlay.dart` is the only Dart code that calls `allowLandscape(true)`.
The Android checks are unchanged.

## Not checked

The rotation itself needs real devices: an iPhone on iOS 16 or later and on iOS 15, and an Android phone and tablet.
Flutter tests run as a desktop host, so they cover the Dart half (asking, giving back, the swapped size and the landscape layout) through a fake channel.

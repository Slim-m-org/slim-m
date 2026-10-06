# Linux/Wayland: switching the shared screen mid-call

Owner's report: after choosing a screen to share, clicking share again always goes back to the screen chosen first.

## Cause

flutter_webrtc 1.6.0 keeps one `RTCDesktopMediaList` per source type in `FlutterScreenCapture::medialist_` (`common/cpp/src/flutter_screen_capture.cc`) for the life of the process.
`BuildDesktopSourcesList` only creates a list when none is cached, so the xdg-desktop-portal session, and the screen picked in it, is made once and reused by every later `getSources` and `getDisplayMedia`.
Stopping and restarting a share does not touch that cache.
The app-level "stop, then start again" route (PR #1180's hold-to-change) therefore cannot re-prompt the portal on its own.

This was found by reading the pinned source.
The portal picker cannot be driven non-interactively, so the failure was not reproduced on a live Wayland session, and neither was the fix.

## Upstream status

flutter_webrtc 1.6.1, 1.6.2 and 1.6.2+hotfix.1 to +hotfix.3 (up to 2026-09) do not change this file's caching, per the changelog.
A version bump is therefore not a fix.

## What ships in the app

`WebrtcDesktopSources.list()` on Linux first calls the plugin method `resetDesktopSources` on the `FlutterWebRTC.Method` channel, then enumerates as before.
Against an unpatched plugin the call throws `MissingPluginException`, which is swallowed, so behaviour is unchanged until the plugin is patched.

## The plugin patch

`reset-desktop-sources.patch` adds `resetDesktopSources`, which clears `medialist_` and `sources_`.
It applies with `patch -p1` from the root of a flutter_webrtc 1.6.0 checkout and touches three files under `common/cpp`.
It is not yet compiled or run against libwebrtc, only checked to apply cleanly.

The patch has since been compiled: `flutter build linux --release` builds it into the plugin.
It has not been run on a live Wayland session.

## The fork

The patch is carried as a git dependency.

- Fork: https://github.com/Slim-m-org/flutter-webrtc
- Branch: `fix/desktop-getusermedia-off-main`, two commits on top of the `v1.6.0` tag: `52a0c681c9173b9dab6fda9f761d56d708cc58a5` (reset desktop sources) and `b30c7e532d167fc3e4f584c86afe1730b0395e7a` (open the camera off the platform thread, and run task runner tasks unlocked).
- Pinned commit: `b30c7e532d167fc3e4f584c86afe1730b0395e7a`.
- Wired in `client/pubspec.yaml` as a `dependency_overrides` entry, not in `packages/rtc`, because `livekit_client` 2.10.0 needs `flutter_webrtc` hosted and pub allows one source per package.

## Bumping flutter_webrtc

1. In a clone of the fork, fetch upstream's tags from `https://github.com/flutter-webrtc/flutter-webrtc.git`.
2. Check whether the new release changed `FlutterScreenCapture` caching, or added its own reset, and whether `GetUserMedia` still opens the camera on the platform thread. Drop whichever patch upstream made unnecessary.
3. Otherwise branch from the new tag and cherry-pick both commits, fixing conflicts in `common/cpp`.
4. Push, and put the new commit SHA in `client/pubspec.yaml`.
5. Run `flutter pub get` (without `--enforce-lockfile`), confirm `livekit_client` still resolves, and run `flutter build linux --release`.
6. Manual check on the Fedora KDE Wayland box: share a screen, hold the share button, pick another screen or window, and confirm peers see it. Then turn the camera on in a call and confirm the window keeps animating while it opens.

Optionally offer the same patch upstream.

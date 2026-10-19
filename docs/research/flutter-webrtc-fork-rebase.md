<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Rebasing the flutter_webrtc fork onto 1.6.2+hotfix.4

Trial date: 2026-10-19.
Fork: `github.com/Slim-m-org/flutter-webrtc`, pinned at `c4026c6` (upstream v1.6.0 plus 21 desktop commits).
Target: upstream tag `v1.6.2+hotfix.4` (`24c85d6`), the version `livekit_client` 2.13.1 asks for.
Trial branch: `rebase/1.6.2-trial` in `~/.slimm-scratch/flutter-webrtc`, tip `a5d9427`, local only, nothing pushed.
Background: [0075](../decisions/0075-livekit-client-2-13.md) left the fork on 1.6.0 and named this rebase as the follow-up.

## Result in one paragraph

The 21 commits replay onto hotfix.4 with three conflict spots in three commits, all resolved by hand.
libwebrtc m144 to m150 changes the C++ headers only additively (`InitializeWithFieldTrials`, `rtc_field_trials.h`, one RTCConfiguration flag), and the audio device, audio processing, capture and video frame headers are byte identical.
Linux builds, the native tests, `dart analyze`, the rtc suite and the app suite pass against the trial branch.
Nothing here proves behaviour on Windows, macOS or iOS, and m150's audio internals can still move levels, so a Windows build and an ear check are required before the pin moves.

## Upstream commits that matter to us

Range `v1.6.0..v1.6.2+hotfix.4` is 31 commits.
Android-only and example-app commits are left out of the table.
Commits after hotfix.4 on `upstream/main` are listed at the end.

| Upstream | What | Why it matters |
| --- | --- | --- |
| 456354f, 4ee09b8 | libwebrtc m150 (Win/Linux prebuilt, then a WARP fix) | New native lib under the gate, rnnoise chain and device code. |
| 81c7c3e, 486cc79 | `enableWARP` and `zeroPlayoutDelay` on `initialize`, SNAP | Off unless set; livekit 2.13 passes them only when set. |
| b91d28c | Do not touch the WebRTC API before `EnsureWebRTCInitialized` | Moves factory, device and audio processing creation out of the constructor. Conflicts with our gate wiring. |
| 1b46f11 | Desktop: resolve remote tracks by id so `setVolume` reaches them | Same fix as half of our `fdcbc21`. |
| 3007eb3 | Windows: `AddTransceiver`/`AddTrack` off the platform thread | Same family as our camera and getStats work; no overlap in code. |
| b836148, ba30ba2 | Desktop screen capture: `cursor` constraint, sanitised source names | The cursor switch we miss; touches `flutter_screen_capture.cc` next to our `resetDesktopSources`. |
| f66fcb5 | Windows: do not unregister event channel handlers after engine teardown | Teardown crash fix. |
| bcc8664 | Desktop: keep the PeerConnection observer alive during disposal | Teardown crash fix. |
| 52274f3, 966485d, 8ecd2e5 | Close data channels before the peer connection is disposed, Dart-side send fence, observer map lock | The data channel dispose fix we miss. |
| 10d179d, 59e40d9, be076d0, 282d6ca, 27957e7, 8be4ecf | Darwin: renderer freed under a first-frame block, plugin singleton, leaked platform views, event channel handlers, audio session lock | The iOS and macOS renderer-dispose crash fix and leaks. |
| 2771134, 258aa26, c1e71cf | Android renderer, data channel handler and camera name fixes | Android only; slim-m Android takes them with the pin bump. |

After hotfix.4, `upstream/main` has 13 more commits.
Worth taking on the next bump: `2a6be75` (Windows renderer released twice on dispose), `db81cea` (`RtpSender.setParameters` writes encodings back), `0db5808` (`captureFrame` leak and busy wait), `db92c74` (Windows lists the host app's own windows), `d18d3f9`/`bf45951` (macOS source discovery off the main thread), `b6d7587` and `381926c` (darwin teardown and null check).
Not worth chasing now: `0cfb0be`/`0ef3eab` (video processors), `4883dae` (Android high speed capture), `593728b` (web).

## Our 21 commits, classified

Categories: (a) generic fix upstream would likely take, (b) slim-m specific, (c) already fixed upstream.
Hashes are the originals; the trial hashes are in `git log v1.6.2+hotfix.4..rebase/1.6.2-trial`.

| Commit | Change | Class | Conflict |
| --- | --- | --- | --- |
| 52a0c68 | `resetDesktopSources` drops cached capture sessions | a (a Wayland portal picker fix; needs a Dart API, so propose it as a small feature) | none |
| b30c7e5 | Open the camera off the platform thread; Linux and Windows task runners no longer run a task while holding the queue lock | a (the task runner hang is a plain bug) | none |
| f860289 | Renderer creates its pixel buffer once | a | none |
| dae4310 | Convert a frame at the drawn size | a | none |
| fdcbc21 | `getStats` off the platform thread | a | yes, see below |
| fdcbc21 | Unified Plan remote tracks by id | c for the lookup, a for the lock | yes, see below |
| 9c318c1 | Native mic noise gate and level meter | b | yes, see below |
| 9c318c1 | Windows default console devices instead of the communications role | b (changes default device policy) | yes, see below |
| 9af7021 | Parenthesise `min`/`max` for `windows.h` | b (fixes our code) | none |
| d928f8b | Compressor and limiter stage | b | none |
| 201319d, 6da7928, 6e9e4ed, d46a0a4 | rnnoise strong suppression and its MSVC/CMake fixes | b | none |
| 1af97b8 | Strong suppression at every capture rate, native tests | b | none |
| f4f4fb4 | rnnoise speech probability drives the gate | b | none |
| 6cacdc9 | `docs/windows-audio-devices.md` | b | none (see the stale audit note below) |
| 1e30d9a | Opt the default audio session out of ducking | b | yes, see below |
| 61d8b3e, a7230da, bd33c8e | Meter reads the compared level; per-session reset; tests | b | none |
| 873d03d | Unpicked mic opens the communications default again | b | none |
| c4026c6 | Gate lookahead, hysteresis, non-finite frames | b | none |

The task said 22 commits; `git log v1.6.0..c4026c6` lists 21.

## Conflicts and how they were resolved

1. `fdcbc21`, `flutter_peerconnection.h` and `.cc`.
   Upstream `1b46f11` added the same `remote_tracks_` map, filled in `OnTrack`, read in `MediaTrackForId`, but with no lock.
   `OnTrack` runs on the signaling thread and `MediaTrackForId` on the platform thread, so upstream's map is a data race.
   Resolution: keep upstream's comment and null checks, keep our `remote_tracks_mutex_` and the three lock guards.
   That lock is the part worth sending upstream.
2. `9c318c1`, `flutter_webrtc_base.cc`.
   Upstream `b91d28c` moved factory, device and audio processing creation from the constructor into `EnsureWebRTCInitialized`.
   Resolution: register `SetCapturePostProcessing` and the Windows default device indices inside `EnsureWebRTCInitialized`, and drop our constructor copy.
   `HandleMethodCall` calls `EnsureWebRTCInitialized()` before every method except `initialize`, which calls it with its options, so every method that reaches the gate or the device list is covered.
3. `1e30d9a`, `flutter_media_stream.cc`.
   We had hooked `OptOutOfAudioDucking()` into `FlutterMediaStream`'s `OnDeviceChange` callback, but upstream moved that callback into `FlutterWebRTCBase`.
   Resolution: delete the `FlutterMediaStream` copy and call `OptOutOfAudioDucking()` in the base callback and once in `EnsureWebRTCInitialized`.
4. Later commits in the series (`d928f8b`, `873d03d`) replayed cleanly on top of those resolutions.

## libwebrtc m150

Headers were diffed from the prebuilt zips, `libwebrtc.m144.7559.09` against `libwebrtc.m150.7871.03` (`libwebrtc-linux-x64-release.zip`; the Windows zip has identical headers apart from line endings).

- `libwebrtc.h`: adds `InitializeWithFieldTrials`.
- `rtc_field_trials.h`: new file.
- `rtc_types.h`: adds `enable_sctp_snap` to the RTC configuration.
- `rtc_audio_processing.h` (the `CustomProcessing` hook our capture chain implements), `rtc_audio_device.h`, `rtc_audio_frame.h`, `rtc_desktop_capturer.h`, `rtc_video_frame.h`: identical.
- Exported symbols of `libwebrtc.so`: the same plus the new field trial entry points.

So nothing in the capture chain, the device code or the post-processor hook needs a source change, and the Linux build confirms it.
What the headers cannot tell is behaviour.
`Process()` still receives 10 ms frames, but m150's noise suppression, AGC2 and echo canceller are newer builds, so the levels our gate and compressor see after them can differ.
The gate threshold (-50 dBFS default), the compressor knee and the rnnoise speech probability cut-offs were tuned on m144.
Windows device enumeration and WASAPI default-device handling live inside the prebuilt, and `docs/windows-audio-devices.md` was audited against m144 only, so that audit needs a re-check, not a trust.

## Test results

| Check | Result |
| --- | --- |
| `cmake -S test/native -B <dir>` and run `native_tests` | built, 0 failures. These use a stub for `CustomProcessing`, so they do not exercise the m150 headers. |
| Fork sources against the real m150 headers | compiled by the Linux plugin build below |
| `flutter build linux --release` (headless, path override) | passed, `build/linux/x64/release/bundle/slimm_app`, downloaded `libwebrtc.m150.7871.03` |
| `dart analyze` (workspace) | no issues |
| `packages/rtc` `flutter test` | 443 passed |
| `packages/app` `flutter test` | 8563 passed, 2 skipped |
| `packages/app` `flutter build web --release` | passed |

The web build does not use the fork at all, so it only proves the lockfile and workspace still resolve with the override.
The trial worktree is `~/.slimm-scratch/wt-forkrebase` (branch `chore/webrtc-fork-1.6.2`).
Its `client/pubspec.yaml` points `flutter_webrtc` at a local path and is not committed.

## Upstream PRs to send (category a)

In order of how likely they are to be taken:

1. Task runner fix on Linux and Windows (from `b30c7e5`): do not run a task while holding the queue lock, so a task that enqueues another does not hang.
2. Lock `remote_tracks_` (from `fdcbc21`): `OnTrack` and `MediaTrackForId` run on different threads.
3. `getStats` off the platform thread (from `fdcbc21`).
4. Open the camera off the platform thread (from `b30c7e5`), after (1), because both edit the same task runner files.
5. Video renderer: create the pixel buffer once (`f860289`), convert at the drawn size (`dae4310`).
6. `resetDesktopSources` (`52a0c68`), as a feature with a Dart API.

Everything else is slim-m specific and stays in the fork.
Once 1 to 5 merge upstream, the fork shrinks to the capture chain, rnnoise and the Windows device code.

## Steps to land

1. Windows build first: after Nick pushes the branch, run `client-windows-ci` `tester_build` against the fork sha (see below) and check the Windows list.
2. In `~/.slimm-scratch/flutter-webrtc`: `git push origin rebase/1.6.2-trial` (Nick; agents do not push).
3. Prefer a new branch name on the remote, for example `slimm/1.6.2`, so `c4026c6` stays reachable for rollback: `git push origin rebase/1.6.2-trial:slimm/1.6.2`.
4. Tag the old pin as well, for rollback: `git tag slimm/1.6.0-final c4026c6`, push the tag.
5. In a slim-m branch, set `client/pubspec.yaml`'s `ref` to the new tip sha (`a5d9427e64b50dda1c74ac54e769bbacd0655282` if no commit is added), run `flutter pub get` without `--enforce-lockfile`, and commit `pubspec.yaml` and `pubspec.lock`.
6. Update `docs/dependencies.md` (the fork is upstream 1.6.2+hotfix.4 plus 21 commits, libwebrtc m150), drop the stale paragraph about the `1.6.2+hotfix.4` mismatch, and record a decision (next free number, 0078 or later) that supersedes the "fork stays" section of 0075.
7. Re-run `scripts/check-dart-licenses.py` (it reads the fork's LICENSE from the pub cache checkout) and the hygiene gates.
8. Run the rtc and app suites, `flutter build linux`, and one `scripts/e2e.sh` voice scenario with `E2E_REBUILD=1`.

## Needs a Windows build and test

Build through `client-windows-ci` `tester_build` after the push, then check on the win11 VM or a real machine:

- It compiles: MSVC with the replayed `windows/CMakeLists.txt`, rnnoise as C11, `windows/audio_ducking_opt_out.cc`, `windows/default_audio_endpoint.cc`.
- Mic open: an unpicked mic opens the communications default, a picked one opens that device, and other apps are not ducked during a call.
- The ducking opt-out still holds after a device change, now that it also runs from `EnsureWebRTCInitialized` and the base `OnDeviceChange`.
- The gate, meter, "Strong" suppression and "Even out loud sounds" behave as before at 44.1, 48 kHz and a Bluetooth headset rate; compare the meter against the same speech on the old build.
- Screen share with and without the new `cursor` constraint, window list (the fork now takes upstream's name sanitising), and a camera open that does not freeze the window.
- Teardown: leave a call and close the app; upstream's `f66fcb5`/`bcc8664` change disposal order.

## Needs a macOS and iOS check

Our commits do not touch `common/darwin`, so macOS and iOS take upstream's 1.6.2 changes unmodified and keep the Webrtc xcframework (`144.7559.10`), not m150.
Risk is the pin move, not our code.

- Build macOS and iOS in CI (the TestFlight job and the macOS client job) and confirm both link.
- iOS: join a call, mute, unmute, switch speaker and leave, then switch a video renderer while frames arrive; this is the crash upstream fixed in `10d179d`.
- iOS: audio session category and interruptions after `8be4ecf`, since the lock handling in `ensureAudioSession` changed.
- macOS: screen share source list after the darwin threading changes.
- The settings path stays "indicator only" on both, as `docs/voice-input-gate.md` says.

## Not verified here

- Anything on Windows, macOS, iOS or Android.
- Real microphone behaviour on m150: no call was made, so gate levels, rnnoise and the compressor are checked only by the native unit tests on the stub.
- Linux desktop run: the bundle was built but not launched.

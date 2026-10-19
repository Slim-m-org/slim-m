<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0078 - The flutter_webrtc fork moves onto upstream 1.6.2+hotfix.4

Status: accepted
Date: 2026-10-19
Supersedes: the "fork left where it is" part of [0075](0075-livekit-client-2-13.md)

## Why

The fork was upstream v1.6.0 plus our desktop commits, while livekit_client 2.13.1 names 1.6.2+hotfix.4.
Staying on 1.6.0 meant missing upstream's libwebrtc m150, the iOS and macOS renderer-dispose crash and leak fixes, data channels closed before a peer connection is disposed, Windows track setup off the platform thread, and the screen-capture cursor constraint.
The owner chose to update on 2026-10-19.

## What changed

Our commits were replayed onto `v1.6.2+hotfix.4` as branch `slimm/1.6.2` in github.com/Slim-m-org/flutter-webrtc.
The Unified Plan remote-track lookup commit was dropped because upstream fixed the same thing; our lock on that map stays, since upstream's map is written on the signaling thread and read on the platform thread.
Three conflicts were resolved: the remote-track map in `flutter_peerconnection`, the capture chain and Windows default devices now hooked into upstream's `EnsureWebRTCInitialized`, and the ducking opt-out moved with upstream's `OnDeviceChange` into the base class.
The m144 to m150 header diff is additive (field trials, SCTP snap); the audio processing, audio device, frame and desktop capturer headers are unchanged, so the capture chain needed no source change.
The old pin stays reachable as tag `slimm-pin-c4026c6`, so rolling back is a one-line `ref` change in `client/pubspec.yaml`.

## What stays ours

The input gate and meter, the compressor and limiter, rnnoise and its build fixes, and the Windows device and ducking code are slim-m specific and stay in the fork.
The thread fixes (task runners, `getStats` and camera open off the platform thread), the renderer pixel buffer and draw-size conversion, and `resetDesktopSources` are generic and are listed for upstream PRs in `docs/research/flutter-webrtc-fork-rebase.md`.

## Risk

m150 brings newer builds of libwebrtc's noise suppression, gain control and echo canceller, so the levels our gate and compressor see may shift from what they were tuned on in m144.
That is checked with the voice quality harness and on real hardware; a regression rolls back by tag.

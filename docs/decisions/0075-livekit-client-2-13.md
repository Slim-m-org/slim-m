<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0075 - livekit_client 2.13.1, with the flutter_webrtc fork left where it is

Status: accepted
Date: 2026-10-18

## Why

`livekit_client` 2.13.0 makes a server-requested session migration (`Leave{action: RESUME}`) resume the session instead of escalating to a full reconnect, so remote participants stop being dropped and re-added.
2.13.0 and 2.13.1 also stop losing reconnect requests: one that arrives while an attempt runs is kept, a reason that needs a full reconnect survives a later request, a resume whose signal socket drops again is retried, and a failed publisher negotiation goes to the reconnect path instead of escaping as an unhandled error.
Every one of those makes a blip less likely to end in `RoomDisconnectedEvent`, which is the only thing our own rejoin reacts to.

## What changed in our use

| Version | Change | Effect here |
| --- | --- | --- |
| 2.11 | Default degradation preference follows the track source | None: `video_publish_options.dart` sets both explicitly. |
| 2.11 | New `DisconnectReason` members, unknown ones fall back to `unknown` | `mapDisconnectReason` names them now (below). |
| 2.11 | `Room.connect` honours its `roomOptions` argument | None: we pass options to the `Room` constructor. |
| 2.12 | Flutter 3.38 / Dart 3.10 floor | None: the workspace is Dart 3.13. |
| 2.12 | Mic permission and audio session failures throw `TrackCreateException` / `AudioSessionException`, not `AudioProcessingException` | None: `mic_failure.dart` classifies on the platform error, and no code catches the old type. |
| 2.13.0 | libwebrtc m150, `enableWARP` and `zeroPlayoutDelay` on `initialize` | Off by default, and we do not set them. |
| 2.13.1 | Camera start bitrate hint capped at 1 Mbps on fast setups, ramping to 300 kbps on slow ones; screen share uncapped | Camera ramps up from a lower start; screen share is unchanged. |

`broadcast_manager.dart` and `track_settings.dart`, the two SDK internals we import, are byte-identical between 2.10.0 and 2.13.1.

## Disconnect reasons

`mapDisconnectReason` now maps `roomClosed` to `removed`, and `signalClose`, `connectionTimeout`, `mediaFailure` and `migration` to `connectionLost`.
Before, a server that sent any of these ended the call as `unknown`, which is not retried; `connectionLost` is, so the automatic rejoin applies.

## Reconnects are not handled twice

Our rejoin (`VoiceControllerRejoinMixin`) runs only after `RoomDisconnectedEvent`, that is after livekit has given up.
livekit's resume and full reconnect run unchanged: no code of ours repairs, retries or restarts anything while the SDK is at it, and none should.
A second layer reacting to the same blip is what the resume fix removes the need for.

Display-only observers are allowed (amended for v121, where the audit found a reconnect invisible for up to about 44 s).
The session listens to `RoomReconnecting`, `RoomResuming`, `RoomAttemptReconnect` and `RoomReconnected` (there is no `RoomRestarted` class in 2.13.1) and to nothing that acts on them.
What they may do is limited to:

- set a reconnecting flag next to `VoiceSessionState`, never a new state, because many gates key on `state == connected`;
- show that flag in the call stage's banner slot after a 2 s debounce;
- hold the roster emit while it is set and rebuild it from the live room afterwards, because a full restart empties the SDK's remote list;
- pause the stall watchdog's recovery and the audio sampling, and clear the ping readout;
- log each transition and count blips into the call summary.

`serverShutdown` and `stateMismatch` now map to `connectionLost` like the other drops, so the automatic rejoin covers them.
`mapDisconnectReason` has a test row for every `DisconnectReason` value, so a value an upgrade adds is decided there.

## The fork stays

`livekit_client` 2.13.1 declares `flutter_webrtc: 1.6.2+hotfix.4`; our fork is 1.6.0 plus our commits.
A `dependency_overrides` entry ignores that constraint, and nothing in 2.13.1's Dart reaches an API the fork lacks: it analyzes, and the two options it adds are sent only when set.
Moving the fork to 1.6.2 would also take libwebrtc m150 into our native noise-gate and device-index patches on all desktop targets, which is a separate, larger change than this one.
What the older fork misses, to weigh in a later rebase: the iOS and macOS crash when a video renderer is disposed with frames still arriving (hotfix.4), closing data channels before a peer connection is disposed, and the screen-capture cursor switch.

## Alternatives

Staying on 2.10.0 keeps the forced full reconnect on migration and the dropped reconnect requests.
Rebasing the fork now buys the iOS renderer crash fix but puts every desktop voice path on a new libwebrtc in the same release as the SDK jump, so a regression could not be placed.

## Also dropped

The `device_info_plus` override in `client/pubspec.yaml` is removed: `livekit_client` 2.11 allows 13.x and `slimm_platform` already asks for `^13.2.0`.

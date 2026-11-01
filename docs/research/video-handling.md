# Video and camera handling in slim-m: current state, best practice, gaps

Research only. Nothing in any repo was changed.
Date: 2026-10-14.
Stack read: livekit_client 2.10.0 (Dart), flutter_webrtc fork `d46a0a4`, LiveKit server v1.10.1.

Legend for confidence:
- VERIFIED-SRC: read directly in the pinned SDK/fork source.
- DOC: stated in a cited primary document.
- UNVERIFIED: my inference or memory, needs a measurement before acting.

## 0. Headline findings

1. **The bitrate and fps ceilings in `ScreenShareQuality` and `CameraQuality` are almost certainly not what is published.**
   `ScreenShareControl.captureOptionsFor` puts `VideoEncoding(maxBitrate, maxFramerate)` in `ScreenShareCaptureOptions.params`.
   In livekit_client 2.10.0 the publish path never reads `params.encoding`.
   `Utils.computeVideoEncodings` (`lib/src/utils.dart:444-505`) takes `options.screenShareEncoding` (a `VideoPublishOptions` field), and when that is null it picks a preset by capture width from `allScreenShare`.
   slim-m never passes `VideoPublishOptions` anywhere (grep of `client/packages` is empty), so `screenShareEncoding` is always null.
   `_findAppropriateEncoding` (`utils.dart:~277`) takes the first preset whose width is >= the capture's longest edge:
   - 720p (1280): `screenShareH720FPS5` = 800 kbps at **5 fps**.
   - 1080p (1920): `screenShareH1080FPS15` = 2.5 Mbps at **15 fps**.
   - 1440p (2560): no preset is wide enough, so the last one, `screenShareH1080FPS30` = 5 Mbps at 30 fps.
   So the 30 fps and 60 fps choices at 720p and 1080p very likely publish with `maxFramerate` 5 or 15 in the RTP encoding.
   That matches "screen share quality concerns".
   Confidence: VERIFIED-SRC for the code path; UNVERIFIED for the observed result.
   First action is a 10-minute measurement: share a 60 fps source at 1080p60 and read the sender's `outbound-rtp` `framesPerSecond`, `targetBitrate`, `frameWidth` (see section 4).
2. **Camera and screen share both use the Dart SDK's default `degradationPreference` = `maintainResolution`** (`local.dart:394`, `:493`).
   The JS SDK documents camera default `maintain-framerate` and screen share `maintain-resolution` (`track/options.ts` doc comment).
   For a camera on a weak uplink, maintain-resolution means frames are dropped to hold 720p, which looks like stutter or a "freeze".
   No `contentHint` is set anywhere (no mention in the Dart SDK, `webrtc_interface`, `dart_webrtc` or the fork).
3. **Nothing in the app collects `getStats` data** (grep for `getStats|framesPerSecond|freezeCount` in `client/packages` is empty).
   There is no way to tell a sender-side cap from a network freeze from a decoder stall.
   The fork already has an off-platform-thread `getStats` (`fdcbc21`), so the plumbing exists.
4. **Desktop (Linux, Windows) remote video is rendered through a CPU path**: `FlutterVideoRenderer` is a `PixelBufferTexture` and `CopyPixelBuffer` calls `ConvertToARGB` per frame (`common/cpp/src/flutter_video_renderer.cc:55-80, 158-168`).
   The fork already converts at the drawn size (`dae4310`), which is the right mitigation.
   Cost scales with tile count x fps x drawn pixels, so a 1440p60 share on a large tile is the expensive case.
5. **Tiles never react to `TrackStreamStateUpdatedEvent`** (server paused the layer for bandwidth) or `TrackMuted` for staleness; `track_event_filter.dart` does not list it.
   A server-paused or stalled track leaves the last decoded frame on screen with no indicator, which reads as a freeze.
6. The screen share ceiling is enforced client-side only (`screenShareMaxHeight` clamps dimensions in `ScreenShareControl._boundedDimensions`); the server grants no per-track cap and the picker tops out at 1440p while the server setting allows 2160.
   Not a bug, but a modified client can publish anything; LiveKit `enabled_codecs` / token grants cannot cap resolution either.

## 1. What the app does today (map)

| Concern | Where | Behavior |
|---|---|---|
| Room options | `client/packages/rtc/lib/src/voice_session.dart:80-87` | `RoomOptions(adaptiveStream: true, dynacast: true)` only. No `defaultVideoPublishOptions`, no `defaultCameraCaptureOptions` override. |
| Camera publish | `voice_session_tracks.dart:108-124`, `video_quality.dart:94-117` | `setCameraEnabled(options: base.copyWith(params: quality.params))`. Presets 360p (450k/20), 720p (1.7M/30, default), 1080p (3M/30). Only the dimensions take effect (see finding 1); the bitrates equal the SDK's own presets so camera is accidentally consistent. |
| Codec | SDK default | `vp8` (`utils.dart:680`). Backup codec default is vp8 too, so no backup is negotiated. |
| Simulcast | SDK default | `simulcast: true`. Camera 720p gets 3 layers: h180 (160k/15), h360 (450k/20), full (1.7M/30) (`video_parameters.dart:74`). Screen share gets full plus one half-size layer (`_computeDefaultScreenShareSimulcastParams`: scale 2, bitrate/4 floored at 150k, same fps). |
| Degradation | SDK default | `maintainResolution` for camera and screen (`local.dart:394`). |
| Content hint | none | Never set. |
| Screen share tiers | `rtc/lib/src/screen_share.dart:12-70`, `docs/video-quality.md` | 720/1080/1440p x 15/30/60 fps, bitrate table 1.0M to 5.0M. `maxFrameRate` is passed as a gUM constraint, so capture honours it; the encoder cap does not (finding 1). |
| iOS share | `screen_share_control.dart:299-303` | Fixed 720x1280 capture (50 MB broadcast extension limit). |
| Share audio | `rtc/lib/src/screen_share_audio.dart` | Web (Chromium) yes; Linux yes via PulseAudio monitor if built with libpulse; macOS, iOS, Android no; Windows code exists but no Windows target documented there (check, a Windows client exists per project notes). |
| Receive quality | `video_quality.dart:14-85` | Auto/Balanced/Data saver map to `setVideoQuality` ceilings (HIGH/MEDIUM/LOW), applied on every room event. Auto leaves publications alone so adaptive stream sizes by tile. |
| Adaptive stream | LiveKit SDK `publication/remote.dart:118-250` | Polls tile `RenderBox` size x devicePixelRatio every 300 ms, debounces settings 1500 ms, pauses the track when no view is visible. |
| Culling | `video_subscription_culler.dart` | After 3 s with no interest (canvas viewport), fully unsubscribes camera and screen tracks (never audio). Resubscribe is immediate. |
| Rendering | `camera_view.dart`, `screen_share_view.dart`, `first_frame_gate.dart` | Own `RTCVideoRenderer` per tile with `cachedRenderer`, `fit: cover` (camera) and `contain` (share), first-frame reveal gate. |
| Local preview pause | `app/lib/src/features/voice/providers/video_pause.dart` | Own preview only stops drawing when hidden/backgrounded; published track and others' video untouched. |
| Camera open | fork `b30c7e5`, `app #2009` | Camera opens on a worker thread (4K UVC took 3.8 s). Pending state in UI. |
| Server | `docker-compose.voice.yml:48-118` | LiveKit v1.10.1, UDP 50000-50100 (101 ports), TCP 7881, TURN/UDP 3478 + relay 30000-30100, TURN/TLS off, no `congestion_control`, no `enabled_codecs`, no `playout_delay`, no `video` or `pli_throttle` overrides, so all defaults. |
| Capacity evidence | `docs/sizing.md:195-215` | 1.3 Mbps per subscriber per camera stream; CPU is not the limit, uplink is. |

## 2. Camera

### 2.1 Capture resolution and fps
Best practice:
- LiveKit presets are 360p 450k/20, 540p 800k/25, 720p 1.7M/30, 1080p 3M/30 (livekit_client `video_parameters.dart`, JS `VideoPresets` in `track/options.ts`).
  LiveKit's own examples capture 720p30 as the default (docs.livekit.io/transport/media/advanced, "Video track configuration").
- Group calls rarely need more than 720p publish when most tiles render at 320x180 to 640x360.
  1080p publish mostly buys a bigger top simulcast layer that is only forwarded to someone with a large tile (adaptive stream plus dynacast make the cost conditional).
Now: 720p default, 360p/1080p options. Reasonable.
Gap: capture fps is not set, so it follows the SDK default for the platform (30 requested).
Phones: 30 fps at 720p is the sweet spot; 1080p on phones raises encoder power and heat (see section 6).
Recommendation: keep the three options; on phones default to 720p and cap 1080p to wifi (low effort).

### 2.2 Simulcast layers and bitrates
Best practice: default LiveKit layers (180p 160k/15, 360p 450k/20, full) are what the SFU and adaptive stream expect (DOC: docs.livekit.io/transport/media/subscribe "Adaptive stream").
Now: defaults, unmodified. Good.
Gap: the lowest layer at 15 fps is fine for a grid tile; nothing to change.
Recommendation: none, but verify via stats that 3 `outbound-rtp` streams (rid q/h/f) exist on every platform, in particular the fork's Android path (`SimulcastVideoEncoderFactoryWrapper.kt`) and desktop.

### 2.3 Codec: VP8, VP9, H.264, AV1, SVC
Facts:
- LiveKit supports H.264, VP8, VP9 (SVC), AV1 (SVC); with VP9 or AV1 it turns on L3T3_KEY, and dynacast can then only pause whole streams, not individual layers (DOC: docs.livekit.io/transport/media/advanced, "Video codec support"; LiveKit KB "Configuring the Client SDK for Optimal Video Quality").
- LiveKit says VP9 gives better perceptual quality per bit than VP8 at higher encode and decode CPU (same KB article).
- The Dart SDK rescales default bitrates by 0.85 for VP9 and 0.7 for AV1 (`utils.dart` `_findAppropriateEncoding`).
- The JS SDK defaults `backupCodec: true` and falls back to VP8 for receivers that cannot decode VP9/AV1; Dart has `BackupVideoCodec` (`options.dart:355`) and `local.dart:902` supports publishing a backup, so it works when the primary is not VP8.
- Hardware encode availability, from the fork source and platform knowledge:
  - Android: the fork ships `SimulcastVideoEncoderFactoryWrapper` and `CustomVideoEncoderFactory` with MediaCodec H.264/VP8 hooks (VERIFIED-SRC).
  - iOS/macOS: libwebrtc's VideoToolbox H.264 (and HEVC if built) (UNVERIFIED for this build).
  - Linux and Windows: the prebuilt libwebrtc used by flutter-webrtc encodes in software (libvpx VP8/VP9, openh264 H.264, libaom/SVT AV1) (UNVERIFIED for this exact build; check `encoderImplementation` in stats).
- Discord uses VP8 and H.264 broadly with HEVC and AV1 on specific platforms, prefers hardware encoders, and renegotiates the codec when members join or leave (DOC: discord.com/blog/how-it-all-goes-live-an-overview-of-discords-streaming-technology).
Now: VP8 simulcast everywhere. It is the lowest-risk choice: every client can decode it, simulcast works on every platform, and dynacast can drop single layers.
Gap: VP8 software encode at 720p x3 layers is the heaviest part of a low-end laptop or phone call, and VP8 is the least efficient codec.
Recommendation:
- Keep VP8 simulcast as the default. Do not move to VP9 SVC yet: dynacast loses per-layer pausing, Safari/iOS cannot encode VP9 (UNVERIFIED, the third-party snippet I found is dated), and software VP9 encode/decode on desktop costs more CPU, which in a 6-8 person call is the wrong direction.
- Evaluate H.264 (hardware) as an opt-in per platform for phones only, after measuring `encoderImplementation` and `powerEfficientEncoder` in stats. Do this as an experiment behind a setting, not a default.
- AV1 only for screen share on capable desktops later (best text compression, W3C content-hint "text" mode enables AV1 screen-content tools), but encoding cost is high and decode support on phones is patchy. Park.

### 2.4 Degradation preference
Best practice: JS SDK default is camera `maintain-framerate` (smooth motion), screen `maintain-resolution`, other `balanced` (livekit client-sdk-js `src/room/track/options.ts` doc on `degradationPreference`).
W3C content-hint: `motion` implies maintain-framerate, `detail`/`text` imply maintain-resolution; an explicit `degradationPreference` overrides (w3.org/TR/mst-content-hint).
Now: Dart default `maintainResolution` for camera (`local.dart:394`).
Gap: under a congested uplink the encoder holds 720p and cuts fps instead of dropping to 540p/360p, which users read as stutter or freeze. Also the 1.7M cap makes this worse.
Recommendation: set `VideoPublishOptions(degradationPreference: DegradationPreference.maintainFramerate)` for the camera. One line in `VoiceSession._buildRoom` via `defaultVideoPublishOptions` (Dart RoomOptions has it). Impact high, effort low.

### 2.5 Backup codec
Only relevant if the primary is not VP8. Not needed now. If H.264 or VP9 is ever the primary, enable `BackupVideoCodec` (vp8) so old clients and web Safari receive something.

### 2.6 What LiveKit recommends for a Discord-like group call
Synthesis of the above: 720p30 capture, simulcast on, VP8 default, adaptive stream and dynacast on, camera maintain-framerate, screen share maintain-resolution with detail/text hint and its own bitrate cap. slim-m already has adaptive stream, dynacast and simulcast; the missing pieces are the explicit publish options and measurement.

## 3. Screen share

### 3.1 Content hint, degradation, codec, bitrate
- `contentHint = 'detail'` or `'text'` for slides, code, documents; `'motion'` for games and video (w3.org/TR/mst-content-hint). The JS SDK exposes `ScreenShareCaptureOptions.contentHint` and sets `'motion'` for SVC screen share (`LocalParticipant.ts`). The Dart SDK and flutter-webrtc expose no `contentHint` setter (no match in the fork or `webrtc_interface`; UNVERIFIED for native libwebrtc, `VideoTrackInterface::set_content_hint` exists in libwebrtc C++ so a small fork patch is feasible).
- LiveKit screen share presets (JS `ScreenSharePresets`): 720p15 1.5M, 720p30 2.0M, 1080p15 2.5M, 1080p30 5.0M, original 7.0M/30.
  Notably 1080p30 is **5 Mbps** in LiveKit's tables versus slim-m's documented **2.4 Mbps**.
- The Dart SDK has no `h720fps30` or `h1080fps60` preset; the largest fps is 30.
- Chrome/libwebrtc caps fps with VP9 SVC L1T3 screen share at 5 fps (JS SDK comment in `LocalParticipant.ts`), another reason to stay on VP8 for screen.
- Discord: the encoder output (fps, resolution, quality) follows the bandwidth estimate; Go Live does not buffer; under severe congestion frames are dropped; the sender never exceeds what the slowest viewer can take (DOC: discord blog "How it all goes live"). Discord's AMD post gives two tuning lessons relevant to any custom encoder path: avoid forcing a keyframe on every parameter update, and do not cap each frame at bitrate/fps because it starves key frames, and leave rate-control headroom so frame drops do not spiral 60 to 30 fps (DOC: discord.com/blog/from-blocky-to-brilliant-improving-video-quality-on-discord-go-live-on-amd-gpus).
  Tiers: a third-party guide reports free 720p30, Nitro 1080p60 and "source" above that; I could not confirm against Discord's own support page, so treat as UNVERIFIED.
Now: capture constraint honours fps and size; encoder cap defaults per finding 1; no hint; maintain-resolution (good for text, bad for games).
Recommendations (ranked):
1. Pass `VideoPublishOptions(screenShareEncoding: VideoEncoding(maxBitrate: quality.maxBitrate, maxFramerate: quality.fps), ...)` on each share publish. Dart's `setScreenShareEnabled` takes `screenShareCaptureOptions`, but `VideoPublishOptions` is room-level (`defaultVideoPublishOptions`) or per `publishVideoTrack`. Options: (a) rebuild `RoomOptions` before each share (room options are fixed at connect, see the comment in `screen_share_control.dart:46`), (b) call `LocalParticipant.publishVideoTrack(track, publishOptions: ...)` yourself after `LocalVideoTrack.createScreenShareTrack`. (b) is the straightforward route. Impact: high. Effort: low to medium.
2. Add a "Text and slides" vs "Motion and games" share mode: motion mode = 60 fps + `maintainFramerate`; text mode = lower fps + `maintainResolution` + higher bitrate per pixel. Today the resolution-and-fps picker is the only control and its fps cap does not apply. Impact: high. Effort: medium (needs a native `contentHint` setter in the fork only if you want the hint itself; `degradationPreference` alone achieves most of it and is already in the Dart API).
3. Re-derive the bitrate table after (1) from measurement. Anchor on LiveKit's 5 Mbps for 1080p30; slim-m's 2.4 Mbps is likely too low for text at 1080p30 with VP8 (VP8 has no screen-content tools). Keep the "do not starve audio" intent by relying on LiveKit congestion control rather than a low static cap, and make it a user-visible per-tier number.
4. Screen share simulcast: the default publishes a half-size second layer (bitrate/4). That is useful for viewers on weak links, and the app's Data saver maps share to MEDIUM. Keep, but note a 1440p/5 Mbps share costs ~6.25 Mbps total uplink with the extra layer (UNVERIFIED, depends on how the layers are allocated).

### 3.2 Max resolution vs bandwidth
Server setting allows 2160, picker allows 1440, iOS is fixed at 720x1280.
Bandwidth reference from the project's own measurement: 1.3 Mbps per camera subscriber (`docs/sizing.md`); a 5 Mbps share to 10 viewers is 50 Mbps server egress, which exceeds many home uplinks. This is the real ceiling, not the encoder.
Measured numbers for a constrained 4K sender are in `screen-share-quality-2026-10-18.md`.
Recommendation: do not add 4K. If asked, gate on the sharer's measured `availableOutgoingBitrate` and VP8 CPU limits; 1440p60 VP8 is already the heaviest pair (`docs/video-quality.md`).

### 3.3 Audio capture per platform
From `screen_share_audio.dart` and the fork: Web (Chromium) yes (tab/system per browser), Linux yes via PulseAudio/PipeWire-pulse monitor, Windows has a WASAPI application-loopback implementation in the fork (`windows/application_loopback_capturer.cc`), macOS no (`FlutterRTCDesktopCapturer.m` hardcodes `audio: false`), iOS no (ReplayKit extension audio would need native work), Android no (`AudioPlaybackCapture` API 29+ is not wired in `GetUserMediaImpl.java`).
Gap: macOS, Android, iOS share without sound. Android is the most tractable (AudioPlaybackCapture API 29+, apps must opt in; many games/media apps do not allow capture). Low priority; park unless users ask.

### 3.4 Wayland and the xdg-desktop-portal
Facts (DOC: flatpak.github.io/xdg-desktop-portal ScreenCast):
- `SelectSources` takes `types` (monitor/window/virtual), `multiple`, `cursor_mode` (1 hidden, 2 embedded, 4 metadata; must be one of `AvailableCursorModes`), `restore_token` and `persist_mode` (0 none, 1 while app runs, 2 until revoked), since v4.
- `Start` returns streams with PipeWire node id, `size`, `source_type`, and a `restore_token`; v6 adds `pipewire-serial`, preferred over node id.
Now: screens only, never windows, because libwebrtc's window enumeration segfaults on Fedora Wayland (`screen_share.dart:90-96`); portal session is cached per process and dropped on switch (`desktop_sources.dart:84-102`, research note `docs/research/linux-wayland-share-switch-2026-09-29`).
Gaps:
- Every share start prompts the portal dialog. `persist_mode=2` plus a stored `restore_token` would let a returning user skip the picker. libwebrtc's portal code does not expose this (UNVERIFIED; it requires a fork patch or a Dart-side portal call over D-Bus). Impact: medium, effort: high.
- Cursor: libwebrtc picks the cursor mode inside its portal code (UNVERIFIED which). If the shared video has no cursor on KDE, `cursor_mode=2 (embedded)` is the fix; test with a share and look at the received tile. Effort: low to find out.
- Window sharing is unavailable; the portal does offer `types` including windows. Only enable once the segfault root cause is fixed (it is in libwebrtc's X11 window enumeration; a portal-only window path avoids enumeration).
Recommendation: first, eyeball cursor presence on KDE Wayland and record the answer in a card; second, scope restore_token support separately.

## 4. Receiving, rendering, freezes

### 4.1 Adaptive stream and dynacast
Best practice (DOC: docs.livekit.io/transport/media/subscribe "Adaptive stream"): the SDK watches element size and visibility, asks the server for the best simulcast layer and pauses hidden tracks. Dynacast (publisher side) stops encoding layers nobody subscribes to; with SVC codecs it can only pause the whole stream (DOC: advanced page).
Now: both on. The Dart implementation computes size from the tile's `RenderBox` x devicePixelRatio, takes the max over all views of the track, debounces 1500 ms, polls every 300 ms (`publication/remote.dart:118-250`).
Gaps:
- A pop-out window, mini-player and grid tile for the same track all register views; the largest wins. Fine.
- 1500 ms debounce means a tile enlarged to fullscreen shows a blurry low layer for up to ~1.5 s plus a keyframe wait. Dart's `quick` flag exists for visibility flips only. UNVERIFIED how the app's fullscreen overlay behaves; test by timing from enlarge to full-resolution `frameWidth`.
- `ReceiveVideoQuality.auto` leaves publications alone, correct. `balanced` and `dataSaver` call `setVideoQuality`, which makes LiveKit "bypass drawn-size sizing whenever layer info is missing" (per the code comment in `video_quality.dart`), a known sharp edge: a Data saver tile that gets enlarged stays low.
Recommendation: make Data saver also respect an enlarged/fullscreen tile (clear the cap while a tile is fullscreen). Low effort, medium impact.

### 4.2 Pausing off-screen and minimised video
Already strong: culler plus adaptive pause plus local-preview pause.
Gap: remote video while the window is minimised or the phone app is backgrounded relies on the canvas interest set; call grid/stage and `CallMiniPlayer` are not clearly covered by `setVideoInterest`. UNVERIFIED; check that a minimised desktop window and a backgrounded phone (non-PiP) result in `UpdateTrackSettings(disabled: true)`. If not, set interest to the empty set on `AppLifecycleState.hidden/paused` unless in PiP. Impact: battery and bandwidth, medium. Effort: low.

### 4.3 Flutter rendering cost
- Desktop: CPU pixel-buffer texture, `ConvertToARGB` per frame at drawn size (VERIFIED-SRC). 8 tiles at 30 fps each convert and upload; this is why the earlier fork commit helped.
- Mobile: Android uses a `SurfaceTexture`/GL path and iOS `CVPixelBuffer` textures (flutter-webrtc standard, UNVERIFIED in this fork).
- Mitigations already in place: own renderer per tile, first-frame gate, event filter so tiles do not rebuild on ActiveSpeakers.
- Missing: a cap on decoded fps for tiny tiles. A 160x90 tile does not need 30 fps; asking the server for the low layer already gives 15 fps (180p layer is 15 fps), so adaptive stream covers this when tile < 320 px.
Recommendation: measure per-tile CPU with 8 remote 720p cameras on the Fedora box (`perf top` or Flutter DevTools timeline) before any rendering rewrite (the repo's own lesson: measure first). If the CPU path dominates, the real fix is a GPU texture path in the fork (large effort) and should not be started on speculation.

### 4.4 Freeze and black-frame failure modes, detection, recovery
Failure modes and how each shows up:
| Mode | Signal | Recovery |
|---|---|---|
| Lost keyframe / decoder desync | receiver `pliCount`/`firCount` rising, `framesDecoded` flat while `packetsReceived` grows | receiver sends PLI automatically; the SFU forwards to publisher, throttled by `pli_throttle` (LiveKit default examples 500 ms low, 1 s mid/high; DOC config-sample.yaml). Tune only if joins show long black time. |
| Server paused the layer (congestion) | `TrackStreamStateUpdatedEvent` paused, `RemoteTrackPublication.streamState` | show a "paused" overlay instead of the stale frame; resumes by itself. |
| Sender stalled (encoder, capture, OS suspend) | `framesEncoded` flat on the sender, `qualityLimitationReason` cpu | sender-side watchdog; toggle capture. |
| Camera device lost or in use | track `ended` / mute event | `track_event_filter` covers muted; verify `ended` is handled. |
| Freeze from jitter or loss | `freezeCount`, `totalFreezesDuration`, `framesDropped` | adaptive stream drops layer; nothing else. |
| Tile never renders (renderer not attached) | `framesDecoded` rising but first-frame gate never fires | re-attach renderer. |
W3C definition of a freeze (DOC: w3.org/TR/webrtc-stats): gap between two rendered frames >= max(3 x average, average + 150 ms) over the last 30 frames; a pause is > 5 s.
Now: none of `freezeCount`, `totalFreezesDuration`, `pliCount`, `keyFramesDecoded` is collected. `TrackStreamStateUpdatedEvent` is ignored by tiles.
Recommendation: a per-tile health sampler (see section 5) that, on `framesDecoded` flat for >3 s while stream state is active, (1) shows a spinner on the tile and (2) logs the stats snapshot; as a first recovery step re-run `setVideoQuality`/`setVideoDimensions` on that publication to provoke a layer switch and keyframe, then resubscribe (`unsubscribe`, `subscribe`). Impact: high for the owner's reported "camera freeze"; effort: medium.

## 5. Network and diagnostics

### 5.1 Congestion control, TWCC, TURN/TCP
- libwebrtc senders use transport-wide congestion control feedback (TWCC) with Google Congestion Control; the LiveKit SFU additionally runs a stream allocator that can pause tracks under severe congestion (`rtc.congestion_control.enabled: true`, `allow_pause: true`, `use_send_side_bwe` default false per the sample config, DOC: github.com/livekit/livekit config-sample.yaml). The sample's default comment may be stale for 1.10; confirm in the running server logs/`/debug` before changing.
- TCP fallback (7881) and TURN/UDP (3478) carry media over a reliable or relayed path: TCP head-of-line blocking turns loss into latency spikes, which show up as bursty freezes and large `jitterBufferDelay`. TURN/TLS is off here (`docker-compose.voice.yml:77`), so a restricted network (UDP blocked, only 443 open) cannot connect at all.
- Narrow UDP range 50000-50100 is fine for ~100 participants (101 ports, one per transport; `docs/sizing.md` says the range is not a participant limit).
Recommendation: log candidate-pair type (host, srflx, relay) and whether `tcp` per client; expose it in the debug panel. If many users are on TCP, enable TURN/TLS and consider `rtc.udp_port` mux. Medium effort, depends on data.

### 5.2 Stats to log (per remote video tile, every 2 s; per local publisher every 5 s)
Inbound (receiver) `inbound-rtp` video: `framesPerSecond`, `framesDecoded`, `framesDropped`, `freezeCount`, `totalFreezesDuration`, `pauseCount`, `keyFramesDecoded`, `pliCount`, `firCount`, `nackCount`, `packetsLost`, `jitter`, `jitterBufferDelay / jitterBufferEmittedCount`, `frameWidth/frameHeight`, `decoderImplementation`.
Outbound (publisher) `outbound-rtp` per rid: `frameWidth/Height`, `framesPerSecond`, `framesEncoded`, `targetBitrate`, `qualityLimitationReason`, `qualityLimitationDurations`, `qualityLimitationResolutionChanges`, `keyFramesEncoded`, `encoderImplementation`, `powerEfficientEncoder`, `active`.
Transport: `candidate-pair` `currentRoundTripTime`, `availableOutgoingBitrate`, `nominated` pair local/remote type.
Definitions: w3.org/TR/webrtc-stats.
In the Dart API: `RTCPeerConnection.getStats()`; livekit_client exposes `LocalVideoTrack.getSenderStats()` and `RemoteVideoTrack.getReceiverStats()` (UNVERIFIED names; check `track/stats.dart`). The fork already runs `getStats` off the platform thread.
Where to put it: a small collector in `client/packages/rtc` that emits a plain record stream, surfaced in a debug overlay and optionally a rate-limited log line (no telemetry leaves the device unless the owner opts in).

## 6. Battery and thermal (phones)
Facts:
- Android exposes `PowerManager.getCurrentThermalStatus()` and a listener (API 29+, device support varies); Google's ADPF guidance is to disable optional power-consuming features, for example reduce video resolution, as severity rises (DOC: developer.android.com/games/optimize/adpf/thermal; source.android.com/docs/core/power/thermal-mitigation).
- iOS exposes `ProcessInfo.thermalState` (nominal, fair, serious, critical) and a `thermalStateDidChangeNotification` (Apple docs; I did not fetch the page, UNVERIFIED wording).
- libwebrtc already adapts encode resolution on CPU overuse (`qualityLimitationReason: cpu`), but only after the encoder is struggling.
Now: nothing thermal. Only local preview pause and PiP.
What to lower, in order, when thermal or battery-saver triggers:
1. Stop rendering your own preview; cheap and already supported.
2. Cap received video: force Data saver (LOW cameras) and unsubscribe tiles beyond the first few.
3. Drop publish camera to 360p/15 fps, or turn the camera off with a prompt.
4. Stop screen share encode at 720p/15.
Recommendation: a small platform channel (`slimm_platform`) exposing thermal state as a stream; a policy object maps `serious` to steps 1-2 and `critical` to 3-4, with a visible banner. Also treat OS battery-saver mode as `fair`. Medium effort, medium impact, high value on the mobile reports.

## 7. Prioritised changes (each can become a Planka card)

### P1. Measure what is actually published (stats collector and debug panel)
- Problem: no visibility into fps, bitrate, layers, codec implementation, limitation reason; every quality claim is currently a guess.
- Evidence: no `getStats` use in `client/packages`; finding 1 can only be confirmed with stats.
- Change: add a stats sampler in `client/packages/rtc` (section 5.2), a "Call stats" debug panel in Voice settings, and a `debugPrint` one-liner per sample. No network upload.
- Risk: `getStats` cost on the platform thread (mitigated by the fork's off-thread fix); keep to 2-5 s intervals.
- Verify: join a call with two clients, confirm numbers match `chrome://webrtc-internals` on the web client.

### P2. Apply screen share encodings and fps for real
- Problem: the bitrate/fps ceilings do not reach the encoder; 30/60 fps picks probably publish 5 or 15 fps.
- Evidence: `utils.dart:444-505`, `_findAppropriateEncoding`, `screen_share_control.dart:281-292` (encoding set on capture params only), no `VideoPublishOptions` in slim-m.
- Change: publish screen share via `publishVideoTrack` with `VideoPublishOptions(screenShareEncoding: VideoEncoding(maxBitrate, maxFramerate), simulcast: true)` built from `ScreenShareQuality`; re-derive the table (start from LiveKit's 1080p30 = 5 Mbps).
- Risk: higher uplink use; mitigate with the table and LiveKit congestion control; iOS 50 MB extension memory must not regress (dimensions stay 720x1280).
- Verify: stats from P1 show `framesPerSecond` ~60 and `targetBitrate` within the tier for a game window at 1080p60; text share at 1080p30 stays sharp.

### P3. Degradation preference per source
- Problem: camera uses maintain-resolution and drops frames on weak uplinks; screen share needs a game mode.
- Evidence: `local.dart:394`, `:493`; JS default doc in `track/options.ts`.
- Change: camera `maintainFramerate`; screen share default `maintainResolution`, with a "Motion" mode using `maintainFramerate` (and a `contentHint='motion'` setter if the fork adds one).
- Risk: camera resolution wobbles under congestion (expected trade).
- Verify: throttle uplink to 1 Mbps with `tc` and compare camera `framesPerSecond` and `qualityLimitationResolutionChanges` before and after.

### P4. Freeze and stall watchdog on tiles
- Problem: stale frames and server-paused tracks look like freezes with no recovery.
- Evidence: `track_event_filter.dart` omits `TrackStreamStateUpdatedEvent`; no health checks; owner reported a camera freeze.
- Change: handle stream-state events (paused overlay); health sampler from P1 flags `framesDecoded` flat >3 s with active stream, shows a spinner, tries layer toggle then resubscribe; log the snapshot.
- Risk: false positives on muted/hidden tracks; gate on subscribed, unmuted, visible, stream active.
- Verify: block UDP to a client for 5 s with iptables, confirm the spinner then recovery; unit test the state machine as `VideoSubscriptionCuller` is tested.

### P5. Fullscreen and Data saver interplay
- Problem: manual `setVideoQuality` caps can leave an enlarged tile soft; 1.5 s settings debounce delays sharpening.
- Evidence: `video_quality.dart` comments; `publication/remote.dart:141`.
- Change: lift the cap while a tile is fullscreen or popped out; measure time to full-res `frameWidth` after enlarge.
- Risk: small.
- Verify: Data saver on, fullscreen a share, `frameWidth` rises to the top layer within ~2 s.

### P6. Background and minimised remote video
- Problem: remote video may keep decoding while minimised or backgrounded if the canvas interest set does not cover those states.
- Evidence: culler is driven by canvas viewport only; `video_pause.dart` covers local preview only.
- Change: on `hidden`/`paused` lifecycle (and not in PiP) call `setVideoInterest({})`; restore on resume.
- Risk: black tile for a moment on return (resubscribe is immediate per culler design).
- Verify: stats show `framesDecoded` flat and server `UpdateTrackSettings(disabled)` while backgrounded.

### P7. Thermal and battery policy on phones
- Problem: nothing reduces video load when a phone is hot or on battery saver.
- Evidence: no thermal code; see section 6.
- Change: platform channel for Android `getCurrentThermalStatus` and iOS `thermalState`; policy steps from section 6; banner.
- Risk: per-OEM variation in Android thermal support; fall back to `qualityLimitationReason == cpu` as the trigger.
- Verify: on a real phone, run a 1080p call for 15 minutes and confirm downgrade steps fire; owner device test is needed (project policy: device behaviour untested without hardware).

### P8. Server config review (low effort, do after P1 data)
- Problem: server runs all defaults; TURN/TLS off; no codec restriction.
- Change: confirm effective `congestion_control` and `use_send_side_bwe` for v1.10.1; consider TURN/TLS on 5349 (already documented in `deploy/README.md`); consider `enabled_codecs` to prevent a modified client from publishing AV1 that old receivers cannot decode.
- Risk: config changes deploy to production; test on a staging compose first.
- Verify: connect from a UDP-blocked network and confirm relay candidate and a working call.

### P9. Wayland portal polish (park until P1 to P4 are done)
- Check cursor visibility on KDE; investigate `restore_token`/`persist_mode=2` for fewer prompts; reconsider window sharing via portal only.
- Measured in v120 with `scripts/linux-portal-probe/run.sh` (nested KWin, D-Bus monitor on the ScreenCast portal):
  - Cursor: `SelectSources` asks for `cursor_mode` 4 (metadata) even though the app's `show_cursor` is true, so the pointer reaches receivers only through libwebrtc's PipeWire cursor monitor and composer.
    That is how Chrome shares on KDE too, but a real pointer over a real shared screen was not seen from a receiver here, so it needs the owner's KDE session.
  - Fewer prompts: libwebrtc already sends `persist_mode` 1 and keeps the portal's restore token in-process, keyed by source id.
    `resetDesktopSources` drops that source on purpose, so every share asks again and sends no `restore_token`.
    `persist_mode` 2 is a libwebrtc setter the plugin cannot reach; it would need a libwebrtc rebuild, and it would stop a share from picking another screen unless the chooser were forced.
  - Windows via the portal: `SelectSources` is asked for `types` 1 (monitors) only.
    Listing windows on Linux uses libwebrtc's X11 window capturer, which aborted the whole process in a session with no X display; the fork now returns an empty list there.
    The chooser offering windows needs `types` 3, which this build does not expose.
- Evidence: xdg-desktop-portal ScreenCast docs; `desktop_sources.dart`.

### P10. Codec experiment (later, data-driven)
- H.264 hardware on phones (opt-in), AV1 for text screen share on capable desktops. Only after P1 shows encoder CPU is the bottleneck (`qualityLimitationReason: cpu`). Park.

## 8. Sources
- LiveKit docs: https://docs.livekit.io/transport/media/advanced/ (codecs, SVC, track configuration), https://docs.livekit.io/transport/media/subscribe/ (adaptive stream, setVideoQuality), https://docs.livekit.io/transport/media/screenshare/, https://docs.livekit.io/transport/media/publish/
- LiveKit server sample config: https://raw.githubusercontent.com/livekit/livekit/master/config-sample.yaml (congestion_control, pli_throttle, enabled_codecs, tcp_port)
- LiveKit JS SDK source: https://github.com/livekit/client-sdk-js (`src/room/participant/LocalParticipant.ts`, `src/room/defaults.ts`, `src/room/track/options.ts`)
- livekit_client 2.10.0 (pub cache): `lib/src/utils.dart`, `participant/local.dart`, `options.dart`, `types/video_parameters.dart`, `publication/remote.dart`, `track/options.ts` equivalents
- Discord engineering: https://discord.com/blog/how-it-all-goes-live-an-overview-of-discords-streaming-technology, https://discord.com/blog/from-blocky-to-brilliant-improving-video-quality-on-discord-go-live-on-amd-gpus
- W3C: https://www.w3.org/TR/mst-content-hint/, https://www.w3.org/TR/webrtc-stats/
- xdg-desktop-portal: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html
- Android thermal: https://developer.android.com/games/optimize/adpf/thermal, https://source.android.com/docs/core/power/thermal-mitigation
- Local: `docs/video-quality.md`, `docs/sizing.md`, `docker-compose.voice.yml`, fork `common/cpp/src/flutter_video_renderer.cc`, `common/cpp/src/flutter_screen_capture.cc`

## 9. Not verified (do before acting)
- That the encoder really publishes 5/15 fps for 720p/1080p shares (P1 settles it; the source path is clear but I did not run a call).
- Whether the fork's libwebrtc build uses hardware encoders on any desktop, and which `encoderImplementation` Android reports.
- LiveKit 1.10.1's effective `use_send_side_bwe` default.
- Discord's current tier table (only third-party reports found).
- Apple `thermalState` guidance (not fetched).
- Whether the call stage, mini-player and pop-out feed `setVideoInterest`.

## Screen-share audio per platform (moved from the code, 2026-10-17)

Whether this platform can publish audio alongside a shared screen, and the honest answer per platform, traced through livekit_client 2.10.0 and the pinned flutter_webrtc 1.6.0 rather than assumed.

[lk.ScreenShareCaptureOptions.captureScreenAudio] exists on every platform, but it is not the flag that actually gates anything.
`LocalParticipant.setSourceEnabled` (`participant/local.dart`) only takes the `createScreenShareTracksWithAudio` path - the one that extracts and publishes an audio track from the captured stream - when its own **top-level** `captureScreenAudio` parameter is true; the options field is only ever consulted by force-copying it to match that parameter, never the other way round.
So this package threads a plain `includeAudio` bool through to that top-level parameter rather than setting the options field, which by itself would change nothing.

**Web (Chromium family) works, source-verified.** `dart_webrtc`'s `MediaDevicesWeb.getDisplayMedia` (`mediadevices_impl.dart`) `jsify()`s the whole constraints map, `audio` included, straight into the browser's own `navigator.mediaDevices.getDisplayMedia`, exactly the shape the W3C Screen Capture spec defines.
Whether a given browser actually offers tab or system audio in its picker is that browser's own business, not this app's: Chromium-family browsers support it, Firefox and Safari do not honour the `audio` constraint there at all.
Either way the failure mode is silent degradation to video-only, never an error - see the platform-split note below - so the toggle is safe to offer on every web build.

**Linux works, conditionally, and the condition is a build-time flag this package cannot see at runtime.** `flutter_webrtc`'s own `linux/pulse_loopback_capturer.cc` streams the default sink's PulseAudio monitor into the captured track, gated at compile time on `HAVE_LIBPULSE`, which `linux/CMakeLists.txt` only defines when `pkg_check_modules` finds `libpulse` and `libpulse-simple` on the build host.
`docs/os_backlog/linux_backlog.md` records this build dependency being added to this project's own CI so a shipped Linux build actually carries it; before that, `CreateLoopbackCapturer` silently returns `nullptr` and a Linux share simply never gets an audio track, no error at any layer.

**macOS and iOS do not, and cannot through this seam at all.** `common/darwin/Classes/FlutterRTCDesktopCapturer.m`'s `getDisplayMedia` hardcodes `'audio': false` and returns an empty `audioTracks` list unconditionally - there is no code path there that ever looks at the `audio` constraint. iOS's screen share does not run through this call at all in the first place: it is `BroadcastManager`'s ReplayKit broadcast extension, whose own audio (system and in-app) arrives through `RPBroadcastSampleHandler`'s separate audio sample-buffer callbacks, a mechanism this package's Dart capture-options seam has no reach into.
Real app-audio-in-broadcast is native Swift work in the extension itself, not a flag here.

**Android does not.** `GetUserMediaImpl.java`'s `getDisplayMedia` builds its `MediaProjection`-backed video capturer and hands back a hardcoded empty `audioTracks` array; nothing in that file touches Android's own `AudioPlaybackCapture` API (available since API 29).

**Windows works (verified 2026-10-18 on the win11 VM, Windows 11 build 26200).**
`flutter_webrtc`'s `windows/application_loopback_capturer.cc` implements the same `LoopbackCapturer` interface Linux does, over WASAPI process loopback, and is reached through this same seam.
With no target process it activates `VAD\Process_Loopback` in `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE` on its own pid, so it captures everything except slim-m itself and a call has no echo.
A probe that replays that exact call sequence (48 kHz 16-bit stereo, shared loopback) measured, with a 440 Hz tone at about -8 dBFS:

| Case | Peak sample | Result |
|---|---|---|
| Unrelated process plays, exclude our own tree | 2640 | captured |
| Only our own process plays, exclude our own tree (a call's own audio) | 1 | not captured |
| Only our own process plays, include our own tree (control) | 2543 | captured |
| Nothing plays | 1 | silent |

A process that is a child of ours (for example a player slim-m launched) is inside the excluded tree and is not captured; an app the user started is not.
Process loopback needs Windows 10 2004 (build 19041) or newer.
On older Windows `ActivateAudioInterfaceAsync` fails, `Start` returns false, and `flutter_screen_capture.cc` carries on with an empty `audioTracks` list, so the share is video only and nothing crashes (read from the fork source, not run on an old Windows).
The probe ran outside the app: it replays the fork's call sequence from PowerShell, because the branch had no Windows build to install.
The in-app path (share dialog, published track, a viewer hearing it) needs the CI Windows artifact of this branch.

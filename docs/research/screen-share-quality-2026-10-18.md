<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Screen share quality for a constrained 4K sender (2026-10-18)

Owner report: a viewer saw Riley's share at 960x540, 3 to 55 fps, 15 freezes, and the call stats read 0.00 Mbps.
Riley published 3840x2160 VP8 simulcast: `q` 1920x1080 at 3 Mbps and `h` 3840x2160 at 12 Mbps, with only `h` carrying an ssrc.

## What was found

1. **The 0.00 Mbps readout was a unit bug.**
   `getStats` stamps reports in microseconds on every native plugin (flutter_webrtc `common/cpp/src/flutter_peerconnection.cc` `timestamp_us()`, the iOS `report.timestamp_us`, Android `getTimestampUs()`) and in milliseconds in a browser.
   `StatsEntry.fromReport` read it as milliseconds, so every desktop and mobile bitrate was 1000 times too low.
   Fixed in `call_stats.dart`, with a test that feeds a microsecond stamp.
2. **`q` had no ssrc because dynacast paused it.**
   livekit_client 2.10.0 `track/local/video.dart` `setPublishingLayersForSender` sets `encoding.active = subscribedQuality.enabled` per layer, and `participant/local.dart` forces dynacast on.
   The SFU only enables the layers somebody subscribed to.
   A viewer with a big tile asks for `h`, so the unused `q` is switched off and never sends; a viewer with a small tile gets `q` and `h` goes quiet (below, `h` shows `active: false`).
   So "only `h` has an ssrc" means the viewer was on the top layer, the 4K one.
3. **Layer choice follows the viewer's tile.**
   In 2160p runs the viewer received the 1920x1080 `q` layer and the 4K layer was never sent, which is the cheap case for the sender.
   With a tile large enough for `h`, the sender encodes 4K, and under CPU or bandwidth limits libwebrtc scales that layer down hard, which is how Riley's viewer ended at 960x540.
4. **The sender was never told.**
   The stats panel already printed `limited by cpu`/`bandwidth` per layer, but only if someone opened it.
   There is now a banner for the sharer.

## Measurements

Harness: `scripts/lib/e2e_share_quality.py`, run by `E2E_ONLY="share reaches the viewer" scripts/e2e.sh` with `E2E_SHARE_MATRIX`.
Real client, real LiveKit, two headless Chromes on this box.
The sharer's `getDisplayMedia` is replaced by a 3840x2160 canvas (text that scrolls in jumps plus a moving gradient), scaled to what the app asks for, as a real capture of a 4K monitor would be.
The viewer's page is 2560 px wide so its tile can use `h`.
15 s warm-up, 30 s measured, numbers from `getStats` deltas on both ends.

"2 cores" pins the sharer's whole browser tree to two cores with `taskset`, which also starves the fake source and the page itself, so it is a harsh, not a typical, weak PC.
"6 Mbps" is an encoder `maxBitrate` set through `RTCRtpSender.setParameters` on every layer, because DevTools network emulation does not shape RTP and a real shaper needs root.
It shows what the encoder does at that budget, not how bandwidth estimation gets there.
The machine was shared with other agents, so treat fps to within a few frames.

| Sender | Tier | Viewer got | Viewer fps | Viewer Mbps | Freezes | Sender limit | Layers sending |
|---|---|---|---|---|---|---|---|
| free | 2160p60 | 1920x1080 | 12.9 | 2.85 | 0 | none | q |
| free | 2160p30 | 1920x1080 | 9.4 | 2.48 | 2 | none | q |
| free | 1440p60 | 2560x1440 | 13.9 | 1.83 | 9 | none | q, h |
| free | 1440p30 | 2560x1440 | 18.6 | 3.72 | 1 | none | q, h |
| free | 1080p30 | 1920x1080 | 28.6 | 3.05 | 0 | none | q, h |
| free | 720p30 | 1280x720 | 26.9 | 1.95 | 0 | none | q, h |
| 2 cores, 6 Mbps | 2160p60 | 960x540 | 10.0 | 1.04 | 1 | bandwidth | q |
| 2 cores, 6 Mbps | 2160p30 | 960x540 | 6.5 | 1.51 | 0 | bandwidth | q |
| 2 cores, 6 Mbps | 1440p30 | 1920x1080 | 2.1 | 2.32 | 0 | cpu | q, h |
| 2 cores, 6 Mbps | 1080p30 | 1280x720 | 7.1 | 3.45 | 0 | cpu | q, h |
| 2 cores, 3 Mbps | 1080p30 | 1280x720 | 5.9 | 2.19 | 0 | cpu | q, h |
| 1 core, 4x CPU throttle | 1080p30 | 1920x1080 | 2.5 | 1.43 | 0 | none | q, h |
| 1 core, 4x CPU throttle | 2160p30 | no video | - | - | - | - | - |

Reading it:

- A constrained 4K sender reproduces the report: 960x540 at 6 to 10 fps, limited by bandwidth, on the `q` layer.
  The same weak sender at 1080p30 gave 1280x720 and the banner would say cpu.
- Free-running 4K tiers are not smooth on this box (9 to 13 fps) because drawing a 4K source in software shares the CPU with the encoder, so they say little about a real GPU-composited desktop.
- The 4K layer is only encoded when a viewer's tile wants it, so most of the cost of a 4K tier is paid by sharers whose viewer is fullscreen or on a large window.
- The 1 core throttled 4K share never produced a first frame within the warm-up, so the viewer saw nothing at all.
- Content matters more than tier: a first pass with a random-noise patch instead of the gradient forced 640x360 at 1440p30 with no cap at all, so the fake source is deliberately mild.

## H264 versus VP8

Not measured.
A page-side `setCodecPreferences` on the screen transceiver did not change the negotiated codec (stats still read VP8, libvpx), because livekit_client chooses the codec itself from `VideoPublishOptions.videoCodec`.
Headless Linux Chrome only has OpenH264 in software anyway, so it could not show the hardware benefit the card hoped for, which needs a real GPU encoder (NVENC, QuickSync, VideoToolbox, MediaFoundation) on the sharer.
livekit_client 2.10.0 scales bitrate only for VP9 (0.85) and AV1 (0.7), not H264.

## What others default to

- LiveKit Meet (`livekit-examples/meet`, `app/rooms/[roomName]/PageClientImpl.tsx`) sets camera presets and simulcast layers only and passes nothing for screen share, so it uses the SDK default.
- The JS SDK default (`client-sdk-js` `src/room/defaults.ts`) is `ScreenSharePresets.h1080fps15.encoding`, which is 1080p at 15 fps and 2.5 Mbps; its 30 fps preset is 5 Mbps (`src/room/track/options.ts`).
- livekit_client 2.10.0 (Dart) picks the preset by capture width, so a 3840 wide capture lands on its largest screen preset, which is where `q` at 3 Mbps and `h` at 12 Mbps come from.
- Discord, from third-party guides only (no official page found): free accounts stream at 720p30, 1080p and anything above (source, 1440p, 4K) needs Nitro; its own blog says the encoder follows the bandwidth estimate and drops frames under congestion (see section 3.1 of `video-handling.md`).

## Never publish above the source (owner rule, same day)

"Riley selected 4k but his display is not 4k", so a share now never goes above the screen it captures.
`fitScreenShare` takes the chosen tier, the space ceiling and the first captured frame's size, and picks the largest tier that fits; layers and bitrate follow it.
The 2160p tier on a 1080p screen used to hand LiveKit the 2160p30 budget; measured with a fake 1080p screen, 2160p30 picked, the encodings read back from the sender:

| Screen | Tier picked | Top layer before | Top layer after | q layer before | q layer after |
|---|---|---|---|---|---|
| 1080p | 2160p30 | 10.0 Mbps | 5.0 Mbps | 2.5 Mbps | 1.25 Mbps |
| 1080p | 2160p60 | 12.0 Mbps | 8.0 Mbps | 3.0 Mbps | 2.0 Mbps |
| 1440p | 2160p30 | 10.0 Mbps | 7.5 Mbps | 2.5 Mbps | 1.875 Mbps |
| 4K | 2160p30 | 10.0 Mbps | 10.0 Mbps | 2.5 Mbps | 2.5 Mbps |
| 1080p | 1080p30 | 5.0 Mbps | 5.0 Mbps | 1.25 Mbps | 1.25 Mbps |

Received video was unchanged for these unconstrained senders (1080p screen: 1920x1080 at about 28 fps either way), because the web client already laid layers out from `getSettings`.
The saving is the budget and, on desktop, where `getSettings` does not exist, the layout too: LiveKit was told 3840x2160 for a 1080p screen.
The source size comes from the first frame of the captured stream, which works on every platform; if it never arrives within 3 s the share publishes as chosen.
Windows are not shared yet, so there is no window case; a window would come through the same read.
Voice settings now says "Larger than your screen, so it is shared at your screen size." under a resolution above every display.
The default e2e run checks it: a 1080p fake screen with 2160p picked must publish a top layer of at most 5 Mbps.
Not exercised: the desktop first-frame read on a real Linux or Windows share (only the web path ran here).

## What changed, and what did not

Changed because the numbers prove it:

- The inbound and outbound bitrate readout (unit bug).
- A share is capped to the source's size and budget (above).
- A banner tells the sharer once per share when the encoder reports `cpu` or `bandwidth` limits twice in a row, and says to lower the resolution or frame rate.

Not changed:

- The default tier stays 1080p30, which is already what a new install uses (`ScreenShareQuality.standard`).
  Riley chose a 2160p tier or an older build was in use; nothing here shows the default itself is wrong.
- The 2160p tiers stay for strong senders.
  The banner is the guard for weak ones.
  The numbers do not show a different bitrate table would help, because the limit was the sender's CPU and uplink rather than the ceiling.
- `screen_share_max_height` (2160 on prod) only clamps the capture size in `ScreenShareControl.captureOptionsFor`; it does not pick a tier.
  Lowering it to 1440 or 1080 would cap the capture and so the cost of a 4K choice, but it is the space's decision and nothing here argues for changing prod.

Open: measure H264 on a machine with a hardware encoder, and re-run the 4K rows on real hardware without a software-drawn source.

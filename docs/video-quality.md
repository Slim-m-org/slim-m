# Video quality choices

Three independent choices, all stored on the device and edited in Voice settings.

## Where each one lives

- Screen share resolution (720p, 1080p, 1440p, 2160p) and frame rate (15, 30, 60 fps): Voice settings and the screen share button's options menu.
  They are the only quality choices in that menu, because they are the only ones about the share.
- Camera quality (360p, 720p, 1080p): Voice settings only.
  The camera button has no options menu, and a menu on it just for this was not worth the extra control.
- Watching quality (Max, Auto, Balanced, Data saver): Voice settings, and the quality chip on a share's control strip in the call.
  It caps the layer received, and the pixel size of that layer depends on what each sender publishes, so it keeps plain words instead of invented numbers.
  Data saver asks for the lowest layer of cameras and of shares (960x540 for a share, which publishes only two layers); an enlarged or popped-out tile always gets the top layer.
  The setting is global, so the chip's menu is headed "Watching quality (all streams)" and a pick there changes every stream and camera, written through the same `receiveVideoQuality` setting Voice settings edits.

## The share's control strip

A share's stage in the call shows a strip along its top right edge: the stream volume (when the share has sound and the stage is at least 400 wide), the live quality chip, full screen, and a button for the tile's menu.
- It shows while a pointer is over the stage or keyboard focus is inside it, and for four seconds after a touch; an open menu or a volume drag holds it up.
  Hidden, it is not built, so nothing samples quality until it shows.
- The chip reads what is arriving now (for example `1080p 30`) from the call stats sampler, and opens the Watching quality pick.
  Your own share has no chip, since there is nothing received to measure.
- The strip sits beside the stage's double-click target, so a double press on one of its buttons never enters full screen.
- Everything on the strip is also in the tile's context menu, which a long press opens on touch.
- Full screen has its own strip along the bottom: the share's volume (a remote share with sound), mute and deafen.
  Leave is left off on purpose, since it is one tap from a video you are only watching.

## Screen share bitrate ceiling

The ceiling is a pure function of the pair, in `ScreenShareQuality.bitrateTable`.
It reaches the encoder through `VideoPublishOptions.screenShareEncoding` (see `screen_share_publish.dart`); capture params alone never set the encoder's bitrate or frame rate, so before this the 30 and 60 fps picks published whatever LiveKit's width-based preset said (as low as 5 fps).
Bits per second:

| | 15 fps | 30 fps | 60 fps |
|---|---|---|---|
| 720p | 1.5M | 2.0M | 3.2M |
| 1080p | 2.5M | 5.0M | 8.0M |
| 1440p | 4.0M | 7.5M | 12M |
| 2160p | 6.0M | 10M | 12M |

- The anchors are LiveKit's own presets: 720p30 is 2.0M and 1080p30 is 5.0M.
- 15 fps costs about half of 30 fps (LiveKit's 1080p15 is 2.5M), and 60 fps about 1.6 times 30 fps, since motion compresses worse but VP8 does not need twice the bits for twice the frames.
- Larger sizes scale with pixels to the power 0.75 from 1080p30, rounded to 0.5M.
- 12M is the top, so one share cannot take a whole home upload.
  A share also publishes a half-size simulcast layer, which adds a fraction on top.
- The simulcast layer and LiveKit's congestion control still lower what is really sent; the numbers above are ceilings.

## Never above the source

A share is never published above the screen it captures or the space ceiling.
Once the track starts, the size of its first frame is read (`screen_share_source_size.dart`) and `fitScreenShare` picks the largest tier whose height fits the source, the ceiling and the chosen tier.
The layers and the top bitrate come from that tier, so a 1080p screen with 2160p picked publishes at the 1080p bitrate (5.0M at 30 fps), not 10M.
The frame rate is kept.
Voice settings says "Larger than your screen" under a resolution above every display here.
A window share is not handled separately: windows are not shareable yet (see `video-handling.md`), and a window's size would come through the same first-frame read.

## Degradation preference

When the uplink cannot carry what was asked, the encoder gives something up.
A camera keeps its frame rate and drops resolution (`maintainFramerate`), so motion stays smooth.
A screen share keeps its resolution and drops frames (`maintainResolution`), so text stays readable.
Both are set through `VideoPublishOptions.degradationPreference` in `video_publish_options.dart`.
There is no user-facing motion mode yet.

## Call stats

Troubleshooting has a Call stats row.
Open during a call, it shows the last minute of each person's audio, then every camera and screen share track.
Video is sampled with `getStats`: remote tiles every 2 s, our own published tracks every 5 s.
It shows size, frame rate, measured and target bitrate, codec and implementation, the quality limitation reason, freezes, dropped frames, loss, jitter and the network path.
Sampling runs while the panel is open, while a viewer watches remote video, while we publish a camera or share, or while "Log every sample" is on.
Nothing is uploaded.

The debug log gets one `[call-stats]` line per track every 30 s, so the 200-entry ring keeps the rest of the call.
"Log every sample" writes each sample instead, which is for a short capture.
When a track ends, one `[call-stats] summary` line is logged at info level: seconds per quality limitation reason, mean sent frame rate and bitrate per layer, the encoder, keyframe requests, freezes for a received track, and the time to the first frame.
The time to the first frame is read from samples, so it is only as precise as the sample interval (5 s for our own tracks).

## Copy call diagnostics

Troubleshooting also has a Copy call diagnostics row.
It copies one block of text: the app version and platform, the selected microphone and speaker, the join timings, the network path, the latest `[voice-health]` lines and the latest `[call-stats]` line per track plus any share summaries.
The numbers are kept apart from the debug log, so a busy log cannot push them out.
They stay until the next call starts, and the block says whether a call is active or it shows the last one.
It holds no tokens, addresses or message content, and it is run through the same redaction as the debug log.
A person's display name appears in the per-person audio lines.

## Migration

The old value was one of `smooth`, `balanced`, `crisp` under `slimm.voice.screen_share_quality`.
It is read as 720p60, 1080p30 and 1440p15, and the next write replaces it with an id such as `1080p30`.
An unknown value falls back to 1080p30.

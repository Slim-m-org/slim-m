# Video quality choices

Three independent choices, all stored on the device and edited in Voice settings.

## Where each one lives

- Screen share resolution (720p, 1080p, 1440p, 2160p) and frame rate (15, 30, 60 fps): Voice settings and the screen share button's options menu.
  They are the only quality choices in that menu, because they are the only ones about the share.
- Camera quality (360p, 720p, 1080p): Voice settings only.
  The camera button has no options menu, and a menu on it just for this was not worth the extra control.
- Watching quality (Auto, Balanced, Data saver): Voice settings only.
  It caps the layer received, and the pixel size of that layer depends on what each sender publishes, so it keeps plain words instead of invented numbers.

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

## Degradation preference

When the uplink cannot carry what was asked, the encoder gives something up.
A camera keeps its frame rate and drops resolution (`maintainFramerate`), so motion stays smooth.
A screen share keeps its resolution and drops frames (`maintainResolution`), so text stays readable.
Both are set through `VideoPublishOptions.degradationPreference` in `video_publish_options.dart`.
There is no user-facing motion mode yet.

## Call stats

Voice settings has a Call stats row.
Open during a call, it samples `getStats` for every camera and screen share track: remote tiles every 2 s, our own published tracks every 5 s.
It shows size, frame rate, measured and target bitrate, codec and implementation, the quality limitation reason, freezes, dropped frames, loss, jitter and the network path.
Sampling runs only while the panel is open or "Log to console" is on, and each sample is also printed as one `[call-stats]` line.
Nothing is uploaded.

## Migration

The old value was one of `smooth`, `balanced`, `crisp` under `slimm.voice.screen_share_quality`.
It is read as 720p60, 1080p30 and 1440p15, and the next write replaces it with an id such as `1080p30`.
An unknown value falls back to 1080p30.

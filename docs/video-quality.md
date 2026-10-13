# Video quality choices

Three independent choices, all stored on the device and edited in Voice settings.

## Where each one lives

- Screen share resolution (720p, 1080p, 1440p) and frame rate (15, 30, 60 fps): Voice settings and the screen share button's options menu.
  They are the only quality choices in that menu, because they are the only ones about the share.
- Camera quality (360p, 720p, 1080p): Voice settings only.
  The camera button has no options menu, and a menu on it just for this was not worth the extra control.
- Watching quality (Auto, Balanced, Data saver): Voice settings only.
  It caps the layer received, and the pixel size of that layer depends on what each sender publishes, so it keeps plain words instead of invented numbers.

## Screen share bitrate ceiling

The ceiling is a pure function of the pair, in `ScreenShareQuality`.
Bits per second:

| | 15 fps | 30 fps | 60 fps |
|---|---|---|---|
| 720p | 1.0M | 1.5M | 2.5M |
| 1080p | 1.6M | 2.4M | 4.0M |
| 1440p | 3.0M | 3.6M | 5.0M |

- 1080p30 stays at 2.4M, and 720p60 at 2.5M, what the old Balanced and Smooth tiers published.
- 1440p15 stays at 3.0M, the old Crisp.
- Other cells scale with pixels per second, with a floor for slides and a damped slope at 60 fps, since motion compresses worse but a home upload is shared with the call's audio.
- 5M is the top because 1440p60 is the heaviest pair VP8 in LiveKit handles on a typical desktop encoder.

## Migration

The old value was one of `smooth`, `balanced`, `crisp` under `slimm.voice.screen_share_quality`.
It is read as 720p60, 1080p30 and 1440p15, and the next write replaces it with an id such as `1080p30`.
An unknown value falls back to 1080p30.

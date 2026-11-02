# Screen share and camera: requested versus delivered size (S1, C2)

This note records what could and could not be established for M6 on this box.

## What was measured

No real encode was read back.
The harness has no way to start a share or a camera from the desktop client, `Xvfb` and `xvfb-run` are not installed, and the Wayland portal route needs a picker that a nested `kwin_wayland --virtual` session does not answer.
Everything below is from the fork source and the client code, not from sender stats.

## Source findings

The fork's `GetDisplayMedia` reads only the device id, `frameRate` and cursor (flutter_screen_capture.cc), so the requested width and height never reach the capturer.
The captured frames are therefore the source's own size.
The client already reads the first decoded frame (`measureCapturedSize`) and clamps the declared size down to it.
What it did not do was scale the encoder down when the source is larger than the tier.

| Case | Requested | Declared before | Delivered frames | Top layer before | Top layer now |
| --- | --- | --- | --- | --- | --- |
| 1080p screen, 1080p tier | 1920x1080 | 1920x1080 | 1920x1080 | 1920x1080 | 1920x1080 |
| 4K screen, 1080p tier | 1920x1080 | 1920x1080 | 3840x2160 | 3840x2160 at the 1080p budget | 1920x1080 (scale 2.0) |
| 3440x1440 screen, 1080p tier | 1920x1080 | 1920x1080 | 3440x1440 | 3440x1440 | 2580x1080 (scale 1.333) |
| 2560x1600 screen, 1440p tier | 2560x1440 | 2560x1440 | 2560x1600 | 2560x1600 | 2304x1440 (scale 1.111) |

The "before" columns are derived from the source, not observed.

## Change

`fitScreenShare` now declares the source aspect, rounded even, at the tier height.
It also returns `captureScale`, the ratio of source height to declared height.
After publish, `applyCaptureScale` multiplies every encoding's `scaleResolutionDownBy` by it, so lower layers keep their ratio to the top one.
The bitrate budget and the space ceiling already follow the fitted tier, so they now bound pixels as well.

## Camera (C2)

Not changed.
The camera reports the requested mode as its settings, and the fix is in the fork's native layer, which is outside this repository.
The impact lens already found that the top layer is the camera's native frame either way, so only the lowest layer is smaller than declared.

## Still open

Read the per-rid `frameWidth` from the sampled sender stats on a real Linux share at 4K and ultrawide, and on a 720p-only webcam at the 1080p setting.

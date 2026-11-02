# Screen share and camera: requested versus delivered size (S1, C2)

This note records a real readback of what the Linux client encodes, for audit items S1 and C2.
Every "delivered" cell below is the client's own sender stats (`frameWidth`, `frameHeight`, `framesPerSecond` per simulcast rid), read from the release build with the voice harness on, not inferred from source.

## How it was read

`scripts/lib/e2e_voice_encode.py` (opt in with `E2E_ONLY="encode readback"`) joins a call with the real desktop client and starts a share or the camera from launch flags (`--voice-harness-share=<height>p<fps>`, `--voice-harness-camera=<quality>`).
For a share, the client runs on Xwayland inside a nested `kwin_wayland --virtual` of a chosen size, so the captured screen has a size the run picked.
The camera is the dev box's own EMEET C960 webcam, which delivers 1080p.
The harness prints one line per layer from `CallStatsSampler` after a 25 to 40 second settle.
The stack was the e2e stack (real LiveKit and server), and the build was a release bundle with `--dart-define=SLIMM_VOICE_HARNESS=true`.

## Screen share: requested versus delivered

"Requested" is what the client declares to LiveKit for the tier and source (`fitScreenShare`): top layer, then the low layer at half.

| Screen | Tier | Requested top / low | Delivered top / low | Quality limit |
| --- | --- | --- | --- | --- |
| 1920x1080 | 1080p30 | 1920x1080 / 960x540 | 1920x1080 / 960x540 | none |
| 3840x2160 | 1080p30 | 1920x1080 / 960x540 | 3840x2160 / 1920x1080 | none |
| 3440x1440 | 1080p30 | 1920x1080 / 960x540 | 3440x1440 / 1720x720 | none |
| 2560x1600 | 1440p30 | 2560x1440 / 1280x720 | 2560x1600 / 1280x800 | none |
| 5120x1080 | 1080p30 | 1920x1080 / 960x540 | 3840x810 / 1920x405 | cpu |
| 3840x2160 | 2160p30 | 3840x2160 / 1920x1080 | 2560x1440 / 1280x720 | cpu |

The share is therefore confirmed as S1 describes it: capture ignores the requested size and the encoder gets the source's own frames.
A 4K screen on the 1080p tier encodes a 3840x2160 top layer against a 1080p budget, and the admin ceiling bounds declared size and bitrate but not pixels.
The two `cpu` rows show the software VP8 encoder shrinking the frames itself on this box, so those delivered sizes are below the source.

## The fix in the audit does not take effect on this fork

The audit's Change line for S1 is to call `setParameters` after publish with a larger `scaleResolutionDownBy`.
That was built and read back on the 3840x2160 screen at the 1080p30 tier, with a factor of 2.
- `setParameters` returned true, and reading `sender.parameters` back showed the scaled values (q 4.0, top 2.0), and they stayed that way for 20 seconds.
- The per-rid stats did not move: top stayed 3840x2160 and low stayed 1920x1080 for 40 seconds.
- Setting every encoding inactive and active again after the change did not move them either.

So on the pinned fork (`flutter_webrtc` 5697ace) a post-publish scale is accepted and remembered but never reaches the encoder, and a Dart-side change cannot fix S1.
LiveKit's own encodings always give the top layer scale 1 against the declared dimensions, so the scale cannot be set at publish either.
The Dart change that was tried was therefore removed rather than shipped as a no-op.

## After: the fork scales the capture (2026-11-02)

The fix went into the fork's native capture instead (`Slim-m-org/flutter-webrtc`, branch `v122/honour-share-size`, commit e70a980).
`getDisplayMedia` now reads the width and height of the video constraint.
When either is set, the published track does not read the capturer directly; it reads it through a limiter that scales each frame down to fit the request.
The aspect ratio is kept, both sides stay even for I420, a frame is never upscaled, and a frame that already fits goes on untouched.
The limiter feeds a custom video source, so libwebrtc's own adaptation still works on top of it.
The cost is one extra I420 copy per frame, and a scale that the fork's native test times at 9.9 ms per 3840x2160 to 1920x1080 frame (20 frame average, release build, one core of this box).
That work runs on the capture thread, so it takes about a third of the 33 ms a 30 fps frame has.
The limiter's tap tables are rebuilt on every call, so part of that time is allocation and is a candidate for caching.
Stopping a share removes the limiter's renderer first, which returns once the capture thread has left the callback, so no frame is in flight when the capturer is released.

The same readback (release bundle against the fork, 25 second settle, `share:WxH:tier` cases) now gives:

| Screen | Tier | Declared top / low | Delivered top / low | fps | Quality limit |
| --- | --- | --- | --- | --- | --- |
| 1920x1080 | 1080p30 | 1920x1080 / 960x540 | 1920x1080 / 960x540 | 30 | none |
| 3840x2160 | 1080p30 | 1920x1080 / 960x540 | 1920x1080 / 960x540 | 20 | none |
| 3440x1440 | 1080p30 | 1920x804 / 960x402 | 1920x804 / 960x402 | 21 | none |
| 2560x1600 | 1440p30 | 2304x1440 / 1152x720 | 2304x1440 / 1152x720 | 21 | none |
| 5120x1080 | 1080p30 | 1920x406 / 960x203 | 1920x406 / 960x203 | 24 | none |

The 2560x1600 row is 2304x1440 rather than 2560x1440 because the 16:10 screen keeps its aspect ratio inside the 2560x1440 box.
The two `cpu` rows of the table above are gone: the software encoder no longer has to shrink the frames itself.
The frame rate on the larger screens is below 30 and the cause is not known.
The table before the fix has no fps column, so there is no unscaled baseline to compare with.
The limiter is a suspect, since its copy and scale run on the capture thread; software VP8 encode sharing cores with the e2e stack is another.
Neither was separated here.

The 3840x2160 case also stopped the share after 8 seconds, waited 3, and started it again (`:restart` suffix on the case).
Both transitions logged, the second share reported its layers, and the app ran on to the end of the case with no crash.

`fitScreenShare` now trusts the capture to deliver the tier's box.
A source as wide as the tier keeps the tier, so the 3440x1440 screen declares 1920x804 instead of dropping to 720p, and the own-share preview reads the same scaled size from `localShareCapturedSize`.
The screen overlay picks its monitor by aspect ratio, which scaling preserves.

Windows and elinux compile the same common code, with the same CMake entries, but were not built here.
macOS has its own ScreenCaptureKit capturer and is untouched.

## Camera (C2)

| Setting | Requested top / mid / low | Delivered top / mid / low |
| --- | --- | --- |
| dataSaver | 640x360 / 320x180 | 640x360 / 320x180 |
| balanced | 1280x720 / 640x360 / 320x180 | 1280x720 / 640x360 / 320x180 |
| high | 1920x1080 / 640x360 / 320x180 | 1920x1080 / 640x360 / 320x180 |

With a webcam that does 1080p, delivered equals requested at every setting, so C2 is not reproduced here.
The audit's case needs a 720p-only webcam at the high setting, and this box has none.
That case is still open, and the Windows VM has no webcam to stand in for one either.

## Still open

- Read the per-rid `frameWidth` on a 720p-only webcam at the high camera setting.
- Build the fork on Windows and elinux; only Linux was compiled and run here.
- Read the Windows share back the same way, once the Windows VM can run the harness.
- Find out why the 4K case settles at 20 fps on this box: read the fps of the unscaled path for the same cases, and try caching the scale's tap tables.

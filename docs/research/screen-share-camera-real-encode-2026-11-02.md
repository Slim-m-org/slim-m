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

## The scaler, measured and replaced (2026-11-22)

The limiter's scaler now keeps its taps per source and target size, scales rows first so the column pass runs once per output row, and halves 2:1 sides in a loop the compiler vectorizes (fork commit b11f1af, branch `b41/share-scaler`).
libyuv's `I420Scale` was the first choice, but the prebuilt libwebrtc ships no libyuv headers and exports only its wrapper API, on Linux and on Windows, so it cannot be called from the fork.
The first scaler stays in the fork's native tests as a reference, and every sample of the new one is within one level of it, at the same output sizes.

`frame_fit_bench` (fork `test/native`, release build, median of 60 frames, one core of this box) gives these milliseconds per frame:

| Screen | Target | First scaler | New scaler |
| --- | --- | --- | --- |
| 3840x2160 | 1920x1080 | 11.6 | 2.3 |
| 3440x1440 | 1920x804 | 9.7 | 3.4 |
| 2560x1600 | 2304x1440 | 13.2 | 4.9 |
| 5120x1080 | 1920x406 | 7.3 | 2.4 |

The copy into a libwebrtc frame after the scale costs under 0.1 ms on every row, so it stays; it is also what lets the limiter reuse its buffer while the frame is still in flight.

The readback was run again for three builds of the same client: the share unscaled (limiter bypassed), the first scaler, and the new one.
This time the screen was an Xvfb of the case's size in a container, not a nested KWin, so no KDE program ran on the dev box; the numbers are therefore lower than the KWin ones above and only compare with each other.
Each cell is the top layer's fps from two interleaved runs per build (three for the new one), with the load average of the box between 7 and 12 out of 32 threads.

| Screen | Tier | Unscaled | First scaler | New scaler |
| --- | --- | --- | --- | --- |
| 1920x1080 | 1080p30 | 27, 27 | 27, 27 | 27, 27, 26 |
| 3840x2160 | 1080p30 | 16, 17 | 15, 14 | 16, 20, 15 |
| 3440x1440 | 1080p30 | 24, 19 | 13, 17 | 21, 18, 19 |
| 2560x1600 | 1440p30 | 25, 25 | 18, 15 | 22, 21, 21 |
| 5120x1080 | 1080p30 | 21, 21 | 18, 17 | 20, 22, 21 |

The new scaler brings the scaled share back to about the fps of the unscaled one, and the first scaler was costing 2 to 8 fps on the large screens.
None of the cases reach 30 fps, and the unscaled path does not either, so the scaler was not what held them below it.
The wrapper's capture loop runs the capture, the I420 conversion and every renderer on its thread, then waits a full 1000/fps ms before the next capture (`RTCDesktopCapturerImpl::CaptureFrame`, read from a local copy of the webrtc-sdk wrapper source).
So the frame rate is 1000 / (33 + work) ms: about 5 ms of work gives the 27 fps of the 1080p screen, and a 4K capture with its conversion takes about 30 ms before any scaling.
Reaching 30 fps needs that delay to subtract the time the capture took, which is in the prebuilt libwebrtc, or the fork asking the capturer for a higher rate and letting the video adapter drop back to 30; neither was tried here.

Windows builds the same scaler but was not compiled here; it uses nothing beyond the C++17 standard library, and the Windows native tests run without failing the workflow until they have run green.

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
- Get the large screens to 30 fps; the capture loop below is the next thing to change, not the scaler.

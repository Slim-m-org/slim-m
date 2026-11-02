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
The change that would work is in the fork's native capture (honour the requested width and height in `GetDisplayMedia`, or adapt the output format), which is outside this repository.
The Dart change that was tried was therefore removed rather than shipped as a no-op.

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

- Honour the requested capture size in the fork, then re-run `E2E_ENCODE_CASES=share:3840x2160:1080p30` and expect a 1920x1080 top layer.
- Read the per-rid `frameWidth` on a 720p-only webcam at the high camera setting.

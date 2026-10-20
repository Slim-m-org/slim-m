# Voice bursts: what they are and what removed them

Written 2026-10-19 on `feat/b16-voice-bursts` (base `feat/batch15`), web client, livekit_client 2.13.1, LiveKit server v1.10.1.
Raw JSON: `~/.slimm-scratch/tmp/report-ab/bursts/` (one folder per run, `summary.txt` has the table below).
Each cell is both directions summed, 90 s of speech (or the synthetic tone-sweep clip) per direction, one run.
Single runs are noisy, so read differences of a few counts as nothing.

## Result

- `microphonePublishOptions()` now publishes with RED on and DTX off.
- RED on, under 5% loss with 30 ms jitter: `level_burst` 50 to 2, dropouts 11 to 0, ViSQOL 4.04 to 4.34.
- DTX off, on the gliding-tone clip, clean network: `level_burst` 7 to 0, clipping 6 to 0, peak +6.0 dB to +0.8 dB.
- Cost: RED roughly doubles the audio payload (received 37 to 72 kbps per speaker including RTP overhead), DTX off adds about 3 kbps.

## A livekit_client 2.13.1 trap

`LocalParticipant.publishAudioTrack` sends `disableRed: publishOptions.red ?? true`.
So `AudioPublishOptions.red` defaults to `true` and that DISABLES redundant audio; `red: false` enables it.
Baseline stats confirm it: the default sends about 109 bytes per packet, `red: false` about 222.
The abandoned WIP in `wt-voiceq` (`red: false`) therefore enabled RED, whatever its comment said.
Re-check this on every livekit_client upgrade; `audio_publish_options_test.dart` pins our side only.

## Speech under loss (59 to 90 s each, 4 profiles)

| profile | build | level_burst | dropout | static | ViSQOL | DNSMOS | kbps | peak over ref | 50 ms windows over ref max +3 dB |
|---|---|---|---|---|---|---|---|---|---|
| clean | default | 0 | 0 | 0 | 4.31 | 3.41 | 36.7 | +1.6 | 0 |
| clean | RED | 0 | 1 | 0 | 4.42 | 3.40 | 73.9 | +1.6 | 0 |
| loss2 | default | 0 | 0 | 0 | 4.25 | 3.41 | 37.0 | +1.4 | 0 |
| loss2 | RED | 0 | 0 | 0 | 4.41 | 3.38 | 73.7 | +1.6 | 0 |
| loss5-jitter30 | default | 50 | 11 | 3 | 4.04 | 3.40 | 36.3 | +5.7 | 1 |
| loss5-jitter30 | RED | 2 | 0 | 0 | 4.34 | 3.40 | 71.0 | +1.4 | 0 |
| burst | default | 52 | 20 | 7 | 3.93 | 3.40 | 36.8 | +1.5 | 0 |
| burst | RED | 14 | 14 | 1 | 3.91 | 3.32 | 70.5 | +6.0 | 0 |

The burst profile (long loss runs) still has 14 bursts and 14 dropouts with RED, so RED helps with isolated loss and little with runs of lost packets.

## The loss "bursts" were mostly not loud

`level_burst` compares each frame with the reference frame at the same time, so a word shifted by a few tens of ms counts.
In the earlier baseline every burst checked under loss sat at -16 to -27 dBFS, inside the speech range; the loudest 100 ms of the recording equalled the loudest 100 ms of the clip (-14.5 against -14.4 dBFS), and the peak was +1.4 dB over the clip, the same as on a clean network.
`scripts/lib/voice_burst_abs.py` measures what matters instead: peak and loudest 50 ms against the reference's loudest.
On default speech only one 50 ms window in 4 profiles exceeded it by more than 3 dB (loss5-jitter30, +5.7 dB peak), so the +14 dB figure was relative, not absolute.

## Gliding tone burst (synthetic clip, clean unless noted)

| publish setting | level_burst | clipping | peak over ref | kbps |
|---|---|---|---|---|
| default (48 kbps, DTX on) | 7 | 6 | +6.0 dB | 29.6 |
| DTX off | 0 | 0 | +0.8 dB | 32.8 |
| 64 kbps | 0 | 0 | +0.8 dB | 42.5 |
| 96 kbps | 0 | 0 | +0.8 dB | 69.1 |

An offline "libopus" reproduction with `ffmpeg` is not evidence: ffmpeg's native Opus decoder produces the same +7.6 dB burst, while libopus (`opusdec`, or ffmpeg with `-c:a libopus` on the decoder) does not.
The in-browser result above is the real one.

## Decision on the receive-side limiter

Not built.
The speech bursts were not louder than the speech itself, so a ceiling at -1 dBFS would not have touched them, and the tone burst is gone with DTX off.
A relative limiter (cap the short-term gain at the speaker's running level plus 3 dB) would be needed to act on them; it would hook `SetRenderPreProcessing` next to `SetCapturePostProcessing` in `flutter_webrtc_base.cc` and be tested with `test/native`.
Revisit it only if the owner still hears bursts with RED and DTX off.

## Strong plus gate on the desktop path (coordinator's two questions)

Onsets losing 30 ms or more, strong-gate-on, loss5-jitter30, 200 s per run, 34 onsets per run:

| build | run 1 | run 2 | total |
|---|---|---|---|
| origin/main (fork c4026c6) | 10 of 34, mean 17.9 ms | 9 of 34, mean 20.0 ms | 19 of 68 |
| batch 15 (fork a5d9427) | 4 of 34, mean 6.2 ms | 9 of 34, mean 15.9 ms | 13 of 68 |

No regression under loss: the earlier 1 of 10 against 5 of 10 was sampling noise.
On a clean network batch 15 lost 6 of 35 onsets (mean 7.1 ms, worst 40 ms) against 0 of 34 (mean 2.4 ms) on origin/main; one run each, a small difference worth another look.
The fork's gate, capture chain and noise suppressor sources are identical between c4026c6 and a5d9427; the libwebrtc binary moved from m144 to m150, which is the likelier difference.

Hum floor, strong-gate-on: the -20.8 and -11.1 dB cells are a one-off, not a steady failure.
In the 200 s clean runs the floor was -68.8 dB (batch 15) and -68.6 dB (origin/main).
In the 60 s runs the leak is a single burst of 0.4 to 1.6 s at -37 dB, at the start of the recording near the loop seam of the looped microphone clip, in the gaps before a word.
The 200 s loss runs show it too, on both builds (hum change -16 to -24 dB), again only in the first seconds.
So the cell is real in the sense that Strong with the gate can pass the hum for about a second at the start of a call; the cause is not found, and it is not new in batch 15.

## The shipped configuration: RED on plus DTX off

Same harness and build family; `ship` is this branch's build, `default` the batch 15 build, `RED` the red-only build.
Cells are bursts / dropouts / ViSQOL / peak over reference (dB) / received kbps per speaker, both directions summed, two runs per cell (default and RED: the earlier run plus one new run).

| profile | default (2 runs) | RED only (2 runs) | RED + DTX off (2 runs) |
|---|---|---|---|
| clean | 0 / 0 / 4.31, 4.43 / +1.6, +1.1 / 37 | 0 / 1 / 4.42 / +1.6 / 74 and 0 / 0 / 4.44 / +1.2 / 75 | 0 / 0 / 4.39 / +1.3 / 84 and 0 / 0 / 4.36 / +1.2 / 83 |
| loss5-jitter30 | 50 / 11 / 4.04 / +5.7 and 33 / 2 / 4.15 / +6.0 / 37 | 2 / 0 / 4.34 / +1.4 and 3 / 0 / 4.42 / +1.1 / 71-72 | 1 / 0 / 4.32 / +1.5 and 1 / 0 / 4.33 / +1.3 / 80 |
| burst | 52 / 20 / 3.93 / +1.5 and 39 / 14 / 4.12 / +1.2 / 37 | 14 / 14 / 3.91 / +6.0 and 6 / 12 / 3.96 / +1.3 / 70 | 14 / 11 / 4.05 / +6.0 and 13 / 10 / 4.02 / +6.0 / 79 |

- RED + DTX off is not worse than RED alone on any speech cell by more than run-to-run spread: bursts and dropouts are equal or lower, ViSQOL within 0.1.
- The one cost is bandwidth: about 80 kbps received per speaker (RED alone 72, default 37), because DTX off sends frames through silence too.
- The burst profile keeps about 13 bursts, 10 dropouts and a +6 dB peak with one clipped run in each ship run; RED does not fix long loss runs.
- Gliding tone, clean, RED + DTX off, one run: no clipping and peak +0.8 dB (default +6.0 dB with 6 clipped runs), 67.7 kbps.
  It also showed four 52 ms `level_burst` events at 22-28 s and two 52 ms dropouts in one direction with 2 concealment events on a clean link, which DTX off alone (one run) did not show.
  I read that as a transient network blip on the shared host and not as the old 0.3-0.5 s clipped note, but it is one run, so treat the tone result as "the clipped burst is gone", not as "the tone path is spotless".

### Repeat of the tone clip on a clean link

| run | bursts | clipping | dropouts | clicks | concealment events | kbps |
|---|---|---|---|---|---|---|
| RED + DTX off, first run | 4 | 0 | 2 | 2 | 3 | 67.7 |
| RED + DTX off, second | 0 | 0 | 0 | 2 | 0 | 67.7 |
| RED + DTX off, third | 0 | 0 | 1 | 0 | 0 | 67.6 |
| DTX off only, first | 0 | 0 | 0 | 2 | 0 | 32.8 |
| DTX off only, second | 0 | 0 | 0 | 0 | 0 | 32.9 |

The 52 ms bursts and concealment events did not recur in two further runs, so the first run was the host, not RED.
One 52 ms dropout showed up in the third RED + DTX off run with no concealment event; the clicks at the very start of a recording appear with DTX off alone too, so they are the harness joining the stream.
Two RED + DTX off runs out of three were clean of bursts; the sample is small.

## Shared audio is published apart from the microphone

Shared audio (a game, a video, music) is not speech, so it does not take the microphone's options.
`screenShareAudioPublishOptions()` sends it at 96 kbps with DTX and RED off, and `unprocessShareAudio()` asks a browser's display audio track for no echo cancellation, noise suppression or gain control.
Before this, the room default applied: 48 kbps plus a RED copy, which is about 99 kbps on the wire against about 97 kbps now.
The cost is the same and the primary stream has twice the bitrate (offline Opus on a jazz clip: 20.4 dB SNR at 48 kbps, 26.3 dB at 96 kbps, mono).
LiveKit's capture call takes only `audio: true`, so the switches cannot ride on it; the browser gets them through `applyConstraints` after capture, which I have not verified in a real browser.
The native plugin's `applyConstraints` handles volume only, so desktop does nothing there: the desktop fork's loopback source is a custom source that libwebrtc's processing never sees.
An earlier version assigned `currentOptions` on the track, which reconfigures nothing and would have made a `restartTrack` open the microphone, so it was removed.
A microphone device switch used to call `setDeviceId` on every local audio track, share audio included; it now touches the microphone only.
Stereo needs a TF_STEREO audio feature that livekit_client 2.13.1 does not send, so shared audio is still mono on the wire.

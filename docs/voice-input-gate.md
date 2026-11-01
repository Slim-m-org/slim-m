# Microphone input gate

Owner report, 2026-10-13: "voice activity is not very accurate, its delayed also mics are picking up everything".

Two separate problems hide in that sentence.
The speaking ring was the SFU's `isSpeaking`, which LiveKit reports on a 500 ms interval with two intervals of smoothing, so it lagged by up to a second.
And nothing stopped quiet sound from being sent: echo cancellation, noise suppression and auto gain control were on, but the old "Voice activity sensitivity" slider only filtered the ring, never the audio.

## What runs where

The gate lives in slim-m's flutter-webrtc fork, in `common/cpp/src/flutter_input_gate.cc`, so it covers Linux and Windows.
libwebrtc's audio processing module accepts one capture post-processing step, which runs on every 10 ms frame after AEC, NS and AGC.
The gate measures each frame's RMS level in dBFS and, when the frame is below the threshold and has been for longer than a 300 ms hold, replaces it with silence through a 60 ms fade.
Opening takes a 5 ms fade.
The audio leaves the gate two frames (20 ms) behind the decision, so the gate is already open when the frame that opened it comes out and a soft start of a word is kept: a synthetic fricative at -45 dBFS leading into a vowel keeps about 83% of its last 20 ms, against none without the delay.
That costs 20 ms of capture latency, with the gate on or off, so the delay never changes when the gate is toggled.
Once open, frames up to 5 dB under the threshold still keep it open, so a word fading out does not flutter the gate at the line.
Silence is cheap on the wire: with Opus DTX a closed gate measured about 8 to 112 bytes a second against about 2 KB a second open.

It also tracks voice detection (above the threshold within the hold) whether or not it is silencing, and keeps a meter.
The meter is the loudest 10 ms frame since the app last asked, so it is the same per-frame level the threshold is compared with: after the platform's noise suppression and rnnoise, before the gate.
An earlier meter fell 1.5 dB a frame from its last peak, which kept the bar over the line for up to 160 ms after a single keyboard click that the gate had already ignored.
The settings bar fills in the accent colour while the gate is open and in a neutral one while it is closed, because the hold keeps the gate open for 300 ms after the bar drops below the line.
With Strong on, the gate also reads rnnoise's speech probability: it opens at once when speech is likely (above 0.6) and the level is over the threshold, otherwise only after the level stays 15 dB over the threshold for two frames, so a single keyboard click does not open it; the hold drops to 100 ms when speech is unlikely.
The app reads both through `getInputGate` (`InputGateMonitor` in `slimm_rtc`), at 50 ms while a meter is on screen and slower, or not at all, otherwise (see Resource use).
While it reads at the display rate the local speaking ring follows that voice state directly; otherwise it follows the SFU like the remote rings.

## Settings

On a host with the gate, Voice settings shows the microphone meter with the threshold as its draggable line ("Input sensitivity", stored as `slimm.voice.input_threshold_db`, default -50 dBFS).
Push-to-talk turns the silencing off, since the key already decides when you are heard; the meter and ring keep working.
Elsewhere (web, macOS, iOS, Android) the old indicator-only slider stays until those platforms get a gate of their own.

## Measuring it

A probe that publishes the mic into a local `livekit-server --dev`, toggles the gate and reads both `getInputGate` and the sender's `media-source` level showed: gate closed, sent level 0.0000; gate open, sent level unchanged; gate off, the meter and voice detection still working.

## Evening out loud sounds

Owner, 2026-10-13: "handling harsh noises ... some sort of mic compression might be nice".

The capture step is a short chain (`flutter_capture_chain.cc`): the gate first, so its meter and threshold see the level you actually speak at, then `flutter_voice_dynamics.cc`.
That stage is a compressor on the RMS level (threshold -14 dBFS, 4:1, 6 dB soft knee, 10 ms attack, 150 ms release) followed by a limiter with an instant attack, a 60 ms release and a -1 dBFS ceiling.
The threshold sits above speech that auto gain control has already levelled, so normal talking passes through; a shout is pulled down and no sample leaves above the ceiling.
libwebrtc's own AGC2 limiter would have been the first choice, but the prebuilt only exposes this custom processing hook, not the processing config.

It runs on the speaker's device, so it costs the server nothing.
"Even out loud sounds" in Voice settings turns it off (`slimm.voice.even_out_loud`, on by default); it is sent as `dynamics` on the same `setInputGate` call, which an older native build simply ignores.

Measured with the stage compiled on its own and fed 48 kHz frames:

| Input | In RMS / peak (dBFS) | Out RMS / peak (dBFS) |
|---|---|---|
| Normal speech | -26.0 / -18.7 | -26.0 / -18.7 |
| Loud speech | -20.0 / -12.7 | -20.3 / -13.1 |
| Recorded speech (e2e fake voice) | -19.6 / -8.6 | -20.8 / -9.7 |
| Shout | -8.0 / -0.7 | -15.9 / -8.7 |
| Full-scale square wave | 0.0 / 0.0 | -10.5 / -1.0 |
| 5 ms full-scale plosive | - / 0.0 | - / -1.0 |

It used about 0.05% of one core.

## Strong noise suppression

libwebrtc's own suppressor handles steady hiss well but lets keyboards, fans and room noise through.
"Strong" runs rnnoise 0.2 (xiph, BSD-3-Clause, vendored in the fork under `third_party/rnnoise`) first in the capture chain, so the gate and its meter see the cleaned signal.
It works on 480-sample frames, one 10 ms frame at 48 kHz, so a capture at any other rate (8, 16, 32 or 44.1 kHz, as Bluetooth hands-free headsets deliver) is resampled to 48 kHz for it and back, which costs well under 3 ms of delay; mono and stereo are both handled.
The client reads that flag on every poll; once Strong is the effective choice in a live call with the mic unmuted and it has read false for about 2 s of polls (whatever the rate), the settings row shows "Strong isn't running on this mic.", and hides it after 0.5 s of active polls in a row. Since the plugin resamples, that now points at a plugin or device problem rather than the sample rate, and the debug log records it.
libwebrtc's own noise suppression stays on while Strong is active: rnnoise alone passes steady hiss above about -35 dBFS and a motor hum at any level, and libwebrtc's suppressor run first removes them (docs/research/mic-handling.md, 6.4 and the 2026-10-27 decision).
Strong is therefore only a native gate flag: choosing or leaving it never reopens the capture, and the mic is always opened with libwebrtc's suppression on.
If Strong reads inactive for about 2 s the debug log says so and the settings row shows the note; nothing else changes, because libwebrtc's suppression is already running.

Measured on its own with the e2e fake voice and added white noise: about 0.7% of one core (generic C, no SIMD dispatch), noise alone 30 to 37 dB quieter, speech level unchanged within 0.5 dB.
It adds about 1.4 MB to the desktop plugin.

Voice settings offers "Space default", "Standard" and "Strong" (`slimm.voice.noise_suppression`).
"Space default" follows `space_settings.strong_noise_suppression` (migration 0109), which a server manager sets on the Retention and limits pane and every client reads from `/version`; it is off unless an admin turns it on.
No event announces that setting, so a call rereads it when it starts and then every minute, and a member on "Space default" switches live; a failed read keeps the last known value rather than falling back to Standard.

## Strongest noise suppression

"Strongest" runs DeepFilterNet 3 (libDF 0.5.6 through tract, MIT or Apache-2.0, the model embedded in the library) in the same capture step, on Linux and Windows.
It removes much more than rnnoise of typing, door slams, music and fans; see `docs/research/deepfilternet-evaluation.md` for the numbers, what it does not fix (barks, babble) and the cost.
The fork builds it with cargo into a static library (`third_party/dfn`), so a desktop build needs a Rust toolchain; without cargo the build warns and Strongest runs as Strong.
Windows ARM64 is built without it for the same reason: tract's assembly kernels were not checked there.
The model is loaded only when Strongest is chosen, off the audio thread, and takes about 60 ms and 48 MB; it is let go when another choice is made and the next frame arrives.

DeepFilterNet turns down the first words after a quiet spell, so rnnoise keeps running beside it.
Its speech probability still feeds the gate, one frame late to match DeepFilterNet's extra frame of delay.
When the probability stays above 0.5 for five frames after 200 ms without it, the output is rnnoise's for 200 ms from the word start, fading back over 100 ms, and half rnnoise's while the speech goes on; both only where DeepFilterNet is at least 2 dB under rnnoise on a frame louder than -50 dBFS.
That took the clipped word starts on the evaluation material from 55 of 168 to 6, against 2 for rnnoise alone.

If the model is missing, fails to load or returns a bad frame, rnnoise keeps running alone, so a call never has less suppression than was chosen.
`getInputGate` reports `strongestNoiseSuppression` (DeepFilterNet processed the last frame) beside `strongNoiseSuppression`; with Strongest chosen the settings note "Strongest isn't running on this mic." follows the first, after the same 2 s of polls.
`setInputGate` takes `strongestNoiseSuppression`, which an older native build ignores.

Voice settings offers Strongest as a fourth choice, only where the host can run it (Linux and Windows); the Space default stays Standard or Strong, because the server setting is one boolean.
A saved Strongest on a host that cannot run it is Strong.
The picker is a select row (a sheet on a phone), because four choices wrap in a segmented row at 390 px wide.

## Automatic sensitivity

Owner, 2026-10-14: "option to automatically determine input sensitivity".

"Automatic sensitivity" in Voice settings (`slimm.voice.input_threshold_auto`, off by default) hands the threshold to `NoiseFloorEstimator` in `slimm_rtc`.
It reads the same 50 ms level readings as the meter, takes the 20th percentile of the last 12 s as the noise floor (speech is the loud minority, so it never lifts it), and keeps the threshold 12 dB above that, clamped to -60 to -38 dBFS.
It rises at most 3 dB a second and falls at most 1 dB a second, ignores digital silence (a muted device), and waits for 3 s of readings before moving off the manual value.
The slider then shows where the threshold is but cannot be dragged; turning Automatic off keeps the last value as the manual one.
It is off by default because the estimator has only been checked on synthetic levels, and an existing user who never touched the slider cannot be told from a new one.

## Choosing a microphone

The picker stores the device id (the PulseAudio/PipeWire source name) in `slimm.voice.audio_input_device_id`.
A join passes it as `sourceId`, and the fork's `GetUserAudio` maps it to an ADM index and calls `SetRecordingDevice`.
A change mid-call went through livekit_client's `Room.setAudioInputDevice`, which on desktop only sets the native recording device and the room default.
The published track kept its own old `deviceId`, so any restart of it (unmute, push-to-talk, since capture stops on mute) reopened the previous microphone.
`AudioDeviceSwitching.switchLiveInput` now also calls `LocalAudioTrack.setDeviceId` on every published microphone track, which restarts it on the new device.

## How fast remote rings move

Remote rings come from LiveKit's active-speaker updates.
Measured on 2026-10-13 against `livekit-server` 1.10.1 with LiveKit's Python SDK, one participant switching between silence and a -20 dBFS tone in real time and another timing `active_speakers_changed`:

| `audio` config | start talking to lit | stop talking to clear |
| --- | --- | --- |
| defaults (500 ms, smoothing 2) | 190-610 ms | 700-910 ms |
| `update_interval: 200`, `smooth_intervals: 1` | 30-215 ms | 690-750 ms |
| `update_interval: 100`, `smooth_intervals: 1`, `min_percentile: 20` | 50-120 ms | 140-210 ms |

The last row is what `docker-compose.voice.yml` ships.
Clearing that fast would flicker between words, so the client keeps a ring lit for 300 ms after the SFU drops it (`SpeakingHold` in `slimm_rtc`); the local ring on a host with the input gate already has the gate's own hold and skips this.

## Level outside a call

Owner, 2026-10-18: the setup step and Voice settings said "Join a voice channel to see your level here", and a Reset microphone row asked the user to repair a mic by hand.
libwebrtc only runs its audio processing (and so the gate and its meter) while a track is being sent, so a plain `getUserMedia` track has no level to read.
`LoopbackMicSource` in `slimm_rtc` therefore sends the track to a second peer connection in the same process and mutes what arrives, so nothing plays.
On Linux and Windows the level is `getInputGate`, the same post-suppression reading a call shows; elsewhere it is the sender's `media-source` `audioLevel`, which is not gated or run through rnnoise.
`MicPreviewController` opens it while a screen holds it (`MicPreviewHold`, which lets go when a route covers the screen), a call is not connecting or connected, and the app is focused, and closes it the moment any of those stops.
Changing the microphone picker restarts the preview on the new device.
This path has been unit and widget tested against fakes; it has not been run on real hardware.

## Dead-mic recovery

There is no Reset microphone row.
A lost track, an unplugged chosen microphone, a new system default (when the capture follows the default) and a capture that reads digital silence for 10 s while unmuted each reopen the capture with a backoff (`MicRecovery`, `SilentMicWatchdog`).
Hosts without the gate read the sender's own level once a second for the silence check, counting only exact zero as silence.
Only when recovery gives up does the mic button say "Microphone unavailable, tap to retry", through the existing inline call surface.

## Resource use

Owner, 2026-10-18: "make sure we arent loading those mic indicators and meters when they are not in focus or not needed".
Everything that samples, captures or animates for a level runs only while something on screen needs it and the app is focused; a call keeps only the reads its safety nets need.
The shared signal is `levelDisplayHoldsProvider` (a count of mounted meters, from `LevelDisplayHold` and `MicPreviewHold`, which ignore a covered route via `TickerMode`) together with `appLifecycleProvider` being `resumed`.
`listenLevelDisplayed` listens to those two notifiers directly and tells the session `setLevelDisplayed`.
It must not go through a derived `Provider`: those refresh on a frame, and frames stop while a window is hidden, so a derived "focused" flag kept the old value exactly when the window was minimised.

| Loop | Runs when | Before | After |
| --- | --- | --- | --- |
| Out-of-call preview capture, loopback peers and `getInputGate` poll (`MicPreview`) | a screen holds it, its route is shown, no call is connecting or connected, app resumed | 50 ms; also kept running under a covered route and, minimised, until the next frame | 50 ms; closed (OS mic indicator off) on blur, minimise, background, a covered route, a call, or leaving the screen |
| In-call gate poll, a meter mounted and shown | dock level bar (mic on), Voice settings meter, setup meter, app resumed | 50 ms always | 50 ms |
| In-call gate poll, nothing displayed, mic open | a call is connected, unmuted | 50 ms always | 2 s (dead-mic watchdog needs 10 s of silence) |
| In-call gate poll, nothing displayed, Strong on | same | 50 ms | 1 s (the inactive note needs 2 s of polls) |
| In-call gate poll, nothing displayed, automatic sensitivity on | same | 50 ms | 200 ms (the estimator weights each reading by the time it covers) |
| In-call gate poll, nothing displayed, mic muted or closed | a call is connected | 50 ms always | none: no reading has a consumer (the watchdog and the Strong note only watch an open mic) |
| Sender level poll for the watchdog (hosts without the gate) | a call is connected | 1 s | 2 s |
| Local speaking ring from the gate | the gate is read at the display rate | always during a call | only then; otherwise the SFU's flag, which lags about half a second |
| Speaking ring pulse (`UserAvatar`) | the avatar is speaking and the app is resumed | ran while the window was unfocused | frozen on blur |

Platform channel calls to `getInputGate` per second, counted in a session test at the real 50 ms display interval (the Dart side only; a native CPU figure was not taken, see below):

| State | Before | After |
| --- | --- | --- |
| Muted, nothing shown | 1 | 0 |
| Unmuted, nothing shown | 1 | 0.5 |
| Unmuted, Strong on, nothing shown | 1 | 1 |
| Meter shown (muted or not) | 20 | 20 |

Not measured: process CPU of a real call.
The desktop build needs a LiveKit stack and a virtual PipeWire source, and the cost is dominated by the native frame path (rnnoise about 0.7% of a core, dynamics about 0.05%, above), not the poll.
Pushing readings from native instead of polling is not worth a fork change while the poll is at most 20 calls a second only with a meter on screen.

Not changed: the call clocks tick once a second and the video stats sampler already runs only while its panel listens.
Tested on fakes and fake clocks only (`rtc/test/voice_session_level_rate_test.dart`, `app/test/features/voice/mic_resources_test.dart`); a real-hardware check of the OS microphone indicator is still owed.

## When a setting applies

Live means the call keeps its connection, mute and deafen state and published tracks; a track restart reopens only that one track, after a short debounce.
Verified against the code on 2026-10-27.

| Setting | Applies | Notes |
| --- | --- | --- |
| Microphone, speaker device | Live | Web has no speaker picker. |
| Noise suppression (Space default, Standard, Strong) | Live | Needs the native gate (Linux and Windows desktop). A native gate flag, no restart, and libwebrtc's suppression is on either way. The Space default is reread every minute. |
| Input sensitivity, automatic sensitivity, even out loud | Live | Native gate flags, no restart. |
| Push to talk | Live | |
| Per-person voice and screen volume, local mute | Live | Reapplied on every room event; the debug log has a `Volume x...` line per push (applied, failed, or already applied and skipped). |
| Deafen | Live | |
| Watching quality (including Data saver) | Live | |
| Camera device | Live | |
| Camera quality | Track restart | A running camera restarts after 700 ms. |
| Screen share resolution, frame rate, share audio | Track restart | A running share restarts on the same source after 700 ms; if the source cannot be reused the row says "Applies the next time you share." |
| Adaptive stream, dynacast | Next join | Fixed when the room is created; no setting. |
| Echo cancellation, auto gain, codec, bitrate caps | Not a setting | Always on or chosen by the stack. |

Nothing needs a Rejoin button.
Anyone who still reports a volume that does not land can send the in-app debug log, which carries the `Volume x...` lines.

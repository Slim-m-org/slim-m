# Microphone input gate

Owner report, 2026-10-13: "voice activity is not very accurate, its delayed also mics are picking up everything".

Two separate problems hide in that sentence.
The speaking ring was the SFU's `isSpeaking`, which LiveKit reports on a 500 ms interval with two intervals of smoothing, so it lagged by up to a second.
And nothing stopped quiet sound from being sent: echo cancellation, noise suppression and auto gain control were on, but the old "Voice activity sensitivity" slider only filtered the ring, never the audio.

## What runs where

The gate lives in slim-m's flutter-webrtc fork, in `common/cpp/src/flutter_input_gate.cc`, so it covers Linux and Windows.
libwebrtc's audio processing module accepts one capture post-processing step, which runs on every 10 ms frame after AEC, NS and AGC.
The gate measures each frame's RMS level in dBFS and, when the frame is below the threshold and has been for longer than a 300 ms hold, replaces it with silence through a 60 ms fade.
Opening takes a 5 ms fade, so the start of a word is not clipped by more than that.
Silence is cheap on the wire: with Opus DTX a closed gate measured about 8 to 112 bytes a second against about 2 KB a second open.

It also tracks voice detection (above the threshold within the hold) whether or not it is silencing, and keeps a meter that rises instantly and falls 1.5 dB a frame.
The app reads both through `getInputGate` about every 50 ms during a call (`InputGateMonitor` in `slimm_rtc`).
The local speaking ring follows that voice state directly; remote rings still come from the SFU.

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
It works on 480-sample frames, which is exactly one 10 ms hook frame at 48 kHz; at any other capture rate it passes audio through and `getInputGate` reports `strongNoiseSuppression: false`.
The client reads that flag on every poll; once Strong is the effective choice in a live call with the mic unmuted and it has read false for about 2 s (40 polls), the settings row shows "Strong is off for this mic. It needs a 48 kHz input.", and hides it after 10 active polls in a row.

Measured on its own with the e2e fake voice and added white noise: about 0.7% of one core (generic C, no SIMD dispatch), noise alone 30 to 37 dB quieter, speech level unchanged within 0.5 dB.
It adds about 1.4 MB to the desktop plugin.

Voice settings offers "Space default", "Standard" and "Strong" (`slimm.voice.noise_suppression`).
"Space default" follows `space_settings.strong_noise_suppression` (migration 0109), which a server manager sets on the Retention and limits pane and every client reads from `/version`; it is off unless an admin turns it on, and a call rereads it when it starts.

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

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

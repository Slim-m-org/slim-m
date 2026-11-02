<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0103 - Strong levels the microphone after suppression, not before it

Status: accepted
Date: 2026-11-02
Extends [0075](0075-livekit-client-2-13.md) and the capture chain in `docs/voice-input-gate.md`.

## The ask

Owner, 2026-11-02: "even though I have strong suppression on, things like swallowing or chewing or background noise make it through, even louder than they would normally."
He also asked for proper tests rather than listening sessions, and for Strong to stay off by default until it is validated.

## What was found

Two things, both measured in `docs/research/voice-transients-2026-11-02.md`.

1. A saved Strong was never applied after a restart on a Space that defaults to Standard, so the chain was not running at all for most of the time it was believed to be.
   That is a bug fix in `voice_input_settings.dart`, not a decision.
2. With the chain running, libwebrtc's auto gain (AGC1) sits before it in the audio processing module.
   It lifts a quiet mouth sound by more than it lifts speech, into the level band where rnnoise stops removing it.
   On the real client with recorded chewing: auto gain on, Strong sent chewing 2.2 dB louder than it went in and lip smacks 6 dB down; auto gain off, 2.3 dB down and 11.6 dB down, with speech 2.2 dB quieter at that input and up to 12 dB quieter at a quiet one (the 2026-10-28 P5 measurement).

## Decision

- While a suppressor runs natively (Strong or Strongest on Linux and Windows), the capture opens with libwebrtc's auto gain off, whatever the Advanced "Automatic gain" toggle says, and the chain's dynamics stage levels instead.
  Standard, and every host without the native chain, keep libwebrtc's auto gain.
- The leveler (`VoiceDynamics`, flutter_webrtc fork 5697ace) lifts speech towards -20 dBFS RMS by at most 12 dB.
  It adapts only after five consecutive 10 ms frames the suppressor is at least 80% sure are speech, up at 2 dB/s and down at 10 dB/s, and holds otherwise.
  Everything else leaves at the gain the voice earned, so a sound in a pause can never come out louder than it went in relative to the voice.
  The compressor and limiter run after it as before.
- A Strong switch mid-call reopens the capture once, the same way a filter change does; a push-to-talk capture is reopened muted; a member who already turned auto gain off is not reopened.
- `getInputGate` reports the leveler's gain, so the voice log and the diagnostics export show whether the chain or libwebrtc is levelling.

## Why not the alternatives

- Keeping auto gain on and tightening the gate: the gate opens on rnnoise's speech probability, which is 1.0 on chewing and coughs; a stricter rule clips word starts, which the harness already counts.
- Moving our chain before auto gain: the module runs its own stages first and offers one post-processing hook; there is no way to run after echo cancellation but before gain.
- Turning off libwebrtc's own suppression under Strong (the earlier P4 idea): rnnoise passes the steady hiss and hum libwebrtc removes first, so the two stay stacked; the measured damage was gain, not suppression.
- A newer model: rnnoise and DeepFilterNet both read loud mouth sounds at the microphone as voice, and DeepFilterNet's attenuation and floor settings move them by under 1 dB; that is a separate card.

## How it is held

- `scripts/lib/e2e_voice_transients.py`, opt in with `E2E_ONLY="voice transients"`: the real Linux client under Standard, Strong, Strong with auto gain off and Strongest, scored on recorded CC0 clips of chewing, swallowing, lip smacks and a breath laid in sentence gaps and over speech.
  It fails when a gap event in a Strong arm comes out more than 1 dB louder in its loudest frame, or speech drifts more than 3 dB in any arm.
- Nine native tests in the fork (`test/native/voice_leveler_test.cc`) pin the target, the ceiling, the no-adapt rules for pauses and short bursts, the fast release on loud speech and the off path.
- `rtc/test/native_leveler_test.dart` and `voice_session_capture_test.dart` pin the hand-over: auto gain off at the capture, the leveler flag on the gate, one reopen per switch, none for a member who had auto gain off, none without the native chain.
- Strong stays opt in. The Space default flips only when the owner is happy with it after real calls.

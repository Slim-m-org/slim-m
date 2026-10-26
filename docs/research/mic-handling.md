# Mic handling research for slim-m (2026-10-14)

Scope: read-only research. Nothing was edited, committed or filed.
Evidence tags: [code] = read in our repo or the fork; [src] = read in upstream source; [doc] = vendor documentation; [unverified] = inference that needs an experiment before anyone acts on it.

## 0. TL;DR - what matters most

1. Windows ducking is probably not fully fixed. The fork now opens the default *console* endpoint, but libwebrtc's WASAPI path still tags the stream `AudioCategory_Communications` (core_audio_utility_win.cc `SetClientProperties`). Microsoft's own text says tagging a stream Communications "will let Windows know to pause background music". Role is one trigger, category is another. Needs a test on the win11 VM (see P1).
2. PTT and mute stop the capture device. We use livekit_client defaults, so `stopAudioCaptureOnMute` is true and every PTT press/unmute reopens the device. That costs latency on every press, can flip Bluetooth profiles, and (on Windows) can restart the communications stream. Fix is one option (P2).
3. The noise gate can clip word starts, contrary to docs/voice-input-gate.md. It opens at the first 10 ms frame whose RMS crosses the threshold, with a 5 ms fade. Soft onsets (s, f, th, h, p) sit well below vowel level, so the first tens of ms are zeroed. There is no lookahead and no hysteresis (P3).
4. We compute rnnoise's VAD probability every frame and throw it away (`rnnoise_process_frame` returns it; flutter_noise_suppressor.cc ignores it). It is a better "is this speech" signal than an RMS threshold, and it is free (P3).
5. Only Linux and Windows get the gate, rnnoise and the compressor. Web, macOS, Android and iOS rely purely on the platform APM. That is a deliberate scope, but it means the owner's "mics pick up everything" report is unaddressed on 4 of 6 targets (P6).
6. Publish defaults are LiveKit's music-oriented defaults (48 kbps, DTX on, RED on). Reasonable but unmeasured for voice (P8).
7. We cannot currently see audio quality. No getStats-based health probe exists in the app or CI (P7).

## 1. How the app captures the mic today

### 1.1 Dart side [code]
- `client/packages/rtc/lib/src/voice_session.dart:83` builds `lk.Room` with `RoomOptions(adaptiveStream: true, dynacast: true)`.
- `client/packages/rtc/lib/src/audio_device_switching.dart:47` layers `defaultAudioCaptureOptions: AudioCaptureOptions(deviceId: ...)` on top. Nothing else is overridden, so all other fields are livekit_client 2.10.0 defaults (track/options.dart): echoCancellation true, noiseSuppression true, autoGainControl true, highPassFilter false, voiceIsolation true, typingNoiseDetection true, stopAudioCaptureOnMute true, all `*Mode` automatic.
- Publish options are not set anywhere (grep for AudioPublishOptions/dtx/audioBitrate in client/packages finds nothing). livekit_client defaults: encoding preset music = 48000 bps, dtx true, red true (options.dart ~L476-515; types/audio_encoding.dart: telephone 12k, speech 24k, music 48k).
- There is no user-facing AEC/NS/AGC toggle in the app. The only user knobs: input threshold, "Even out loud sounds", noise suppression Space default/Standard/Strong (providers/noise_suppression.dart, voice_controller_input.dart), push-to-talk.
- Mute and PTT both call `room.localParticipant.setMicrophoneEnabled(bool)` (rtc/lib/src/voice_session_tracks.dart:94, `_trySetMicrophone`; app/lib/src/features/voice/providers/voice_controller_input.dart:143 `setPushToTalkHeld`). With the default `stopAudioCaptureOnMute: true`, livekit_client's `publication.mute(stopOnMute: true)` stops capture (participant/local.dart:779).
- Gate control: `InputGateMonitor` (rtc/lib/src/input_gate.dart) calls the fork's `setInputGate {enabled, thresholdDb, dynamics, strongNoiseSuppression}` and polls `getInputGate` every 50 ms over the platform channel. `supportsInputGate` is Linux+Windows only.
- PTT: gate is disabled (`enabled: !_pushToTalkEnabled`) and the mic track is muted/unmuted by the key.
- Constraint mapping on desktop: fork `flutter_media_stream.cc:232-238` reads `echoCancellation/noiseSuppression/autoGainControl` (default true) and `highpassFilter` (default false) into `RTCAudioOptions`. `typingNoiseDetection`, `channelCount`, `sampleRate` are not read by the desktop C++ (grep) and so are inert there.

### 1.2 Native chain in the fork (Linux + Windows) [code]
Branch feat/voice-dynamics, files under common/cpp/src:
- libwebrtc APM (prebuilt `third_party/libwebrtc/lib/libwebrtc.so`, version not recorded in the repo): AEC + NS + AGC + HPF per `RTCAudioOptions`.
- Then ONE custom capture post-processing hook, `CaptureChain` (flutter_webrtc_base.cc:36 `SetCapturePostProcessing`): `NoiseSuppressor` (rnnoise 0.2, only when frame == 480 samples i.e. 48 kHz, 10 ms) -> `InputGate` -> `VoiceDynamics`.
- InputGate: per 10 ms frame RMS in dBFS vs threshold (default -50). Hold 300 ms, open ramp 5 ms, close ramp 60 ms, meter decay 1.5 dB/frame. Voice state tracked even when not gating.
- VoiceDynamics: RMS compressor (-14 dBFS, 4:1, 6 dB knee, 10 ms attack, 150 ms release) + limiter (instant attack, 60 ms release, -1 dBFS ceiling).
- rnnoise state is re-initialised whenever it is off for a frame; frames that are not 480 samples bypass it silently.

### 1.3 What the prebuilt APM actually runs (derived from upstream source) [src]
`WebRtcVoiceEngine::ApplyOptions` (media/engine/webrtc_voice_engine.cc, main):
- AEC: `echo_canceller.enabled` = echoCancellation (AEC3 on desktop; on Android/iOS the build may use platform AEC, see section 5).
- AGC: `gain_controller1.enabled` = autoGainControl, mode `kAdaptiveAnalog` on desktop, `kFixedDigital` on iOS/Android. AGC2 (`gain_controller2`) is NOT enabled by this code path.
- NS: `noise_suppression.enabled` with level hard-coded to `kHigh`. No API from Dart or from `RTCAudioOptions` changes the level.
- HPF: `high_pass_filter.enabled` = highpassFilter. Our default is false, but AEC3 enforces its own HPF anyway (`echo_canceller.enforce_high_pass_filtering = true` default in api/audio/audio_processing.h).
- Transient suppression ("typing noise detection") is marked "Deprecated. Stop using and remove" (bugs.webrtc.org/357281131) in audio_processing.h. Do not plan around it.
- Upstream `AudioTransportImpl::RecordedDataIsAvailable` no longer feeds an analog mic level back (it calls through with a dummy `new_mic_level`), so on current upstream AGC1 "adaptive analog" is effectively digital only. The prebuilt .so is older/newer than this; it contains the strings `analog_gain_controller { enabled:` and `pa_context_set_source_volume_by_index`, so whether Linux AGC moves the system mic slider on OUR build is [unverified] and must be measured (P5).

## 2. Findings by topic

### 2.1 APM configuration and what other apps do
Best practice:
- WebRTC's own header says defaults are "settings that recommended for most situations" and AGC1 is "recommended to be enabled on the client-side". AEC3 + NS + AGC is the standard trio. LiveKit's docs: leaving WebRTC echo/noise cancellation on is "strongly recommended" unless you add Krisp or ai-coustics (https://docs.livekit.io/transport/media/noise-cancellation/). The Krisp/ai-coustics models are LiveKit Cloud / agent-side; they do not apply to a self-hosted client-to-client call.
- AGC2 (adaptive digital + input volume controller + limiter) is the maintained successor to AGC1 (header marks AGC1's analog fields deprecated). The Voice engine path above only enables AGC1; AGC2 needs the `AudioProcessing::Config` which the prebuilt does not expose (docs/voice-input-gate.md says the same).
- Discord runs Krisp (ML noise suppression, on device, no audio sent to Krisp) and exposes separate toggles for noise suppression, echo cancellation, automatic gain control and automatic input sensitivity (https://discord.com/blog/clean-up-the-noise-with-krisp; their support article on input sensitivity warns auto mode struggles with variable noise, https://support.discord.com/hc/en-us/articles/211376518). Discord's blog does not describe its VAD algorithm; I found no primary source, so treat competitor VAD/gating internals as unknown. Teams uses an on-device deep-learning suppressor with Low/High modes (third-party coverage only). Meet's "denoiser" is also ML (no engineering primary source found).
- Windows 11 24H2 added a system-level Deep Noise Suppression effect GUID for APOs (https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-signal-processing-modes). A system effect plus our rnnoise would be double suppression; see 2.2.

Our state vs best practice:
- We are on the standard trio, and rnnoise on top is the same architecture Discord ships (WebRTC AEC + ML NS), implemented with an older, smaller model. Fine.
- Gap: no way to expose NS level, no AGC2, no per-user toggles for AEC/AGC, which is how Discord handles "my voice sounds wrong" support cases.

Recommendation: add a diagnostics/advanced section (AEC, NS, AGC toggles that map to existing `AudioCaptureOptions`; LiveKit also supports live `LocalAudioTrack.setAudioProcessingOptions` and `AudioManager.getAudioProcessingState()` per audio_manager.dart in 2.10.0). Cheap, Dart-only, helps support (P9).

### 2.2 Chain order and double processing
Facts:
- Our hook runs after AEC, NS and AGC (docs/voice-input-gate.md; confirmed by CustomProcessing placement). That ordering is the right one for the gate and the compressor: AEC must see the unmodified signal relative to the render reference, and nothing should change gain between the capture and the AEC.
- rnnoise after WebRTC NS (kHigh) is two ML/DSP suppressors in series. This is the "double NS" trap: artifacts compound (musical noise, clipped tails). Our doc measured speech level unchanged within 0.5 dB and noise 30-37 dB down, so it works for the owner's case. Risk is quality on quiet/whispered speech, not level.
- AGC1 runs BEFORE rnnoise and the gate. AGC1 raises gain during speech and slowly relaxes in pauses, so the gate threshold (-50 dBFS) is not a stable absolute number: the same voice at the same distance reads differently after AGC adapts. The comment in input_gate.dart already says "once AGC has levelled it", i.e. we depend on it.
- AGC1 has its own limiter (`enable_limiter = true` default) and our VoiceDynamics adds a second compressor/limiter. They do not fight in steady state (ours is above AGC's target), but a hard shout is first limited by AGC1, so VoiceDynamics sees a clipped-ish signal. Order of attack matters little here; keep both.
- rnnoise only runs at exactly 480-sample frames (48 kHz). If a device captures at 44.1 kHz, 16 kHz (Bluetooth HFP) or 32 kHz, strong NS silently does nothing, and `getInputGate` reports `strongNoiseSuppression: false`. The setting looks on in the UI.

Recommendations:
- Keep order AEC -> NS -> AGC -> rnnoise -> gate -> compressor/limiter.
- When strong NS is on, consider turning off WebRTC NS rather than stacking. Not possible from the hook alone; requires passing `noiseSuppression:false` in constraints when `Strong` is chosen. Needs an A/B listen test before committing (P4).
- Surface "strong NS inactive at this sample rate" in the settings UI instead of silently passing audio through (or resample 16k/44.1k -> 48k inside the hook; rnnoise is 48k only).

### 2.3 Sample rate, channels, Opus, what LiveKit exposes
- rnnoise: 48 kHz, 480 samples (https://github.com/xiph/rnnoise/blob/main/include/rnnoise.h).
- Opus in WebRTC: 48 kHz clock, mono capture by default. Our code never sets `channelCount`; desktop ignores it. Mono is correct for speech.
- Opus guidance: VoIP mono 10-24 kbps, "24 kb/s should give fullband" (https://wiki.xiph.org/Opus_Recommended_Settings). Our 48 kbps `presetMusic` is 2x the fullband-voice figure. It buys a little headroom for noisy/music-ish input, at the cost of bandwidth. RED doubles payload per packet on top.
- SDP knobs per RFC 7587 (https://www.rfc-editor.org/rfc/rfc7587.html): `useinbandfec`, `usedtx`, `maxaveragebitrate`, `cbr`, `stereo`, `ptime`. In-band FEC is on by default in libwebrtc's offer; RED for Opus is behind the `WebRTC-Audio-Red-For-Opus` trial string present in the prebuilt.
- LiveKit Dart exposes `AudioPublishOptions(encoding: AudioEncoding(maxBitrate), dtx, red)` and the presets (telephone 12k, speech 24k, music 48k). There is no FEC or ptime or packet-loss-percentage knob in the Dart SDK; those come from libwebrtc.
- DTX interacts with our gate: a closed gate emits digital silence and Opus DTX then sends almost nothing (docs measured 8-112 B/s closed vs ~2 KB/s open). Good. DTX plus RED plus FEC on the same stream is redundant on a LAN; useful on Wi-Fi/mobile.

Recommendation: set `AudioPublishOptions` explicitly (speech preset 32 kbps as an experiment, keep dtx and red) and verify with ViSQOL (section 2.8). Low risk, but get the number from a measurement, not from the wiki (P8).

### 2.4 Voice activity detection
Current: energy gate with a fixed threshold, no lookahead, no hysteresis; 50 ms Dart poll for the ring.
Problems:
- Clipped onsets. Gate stays closed until a frame crosses the threshold, then opens over 5 ms. Weak onset phonemes before that frame are multiplied by ~0. docs/voice-input-gate.md says "the start of a word is not clipped by more than that [5 ms]" which is only true for words that start loud. This is the most likely cause of "feels delayed / words eaten" for some voices.
- No hysteresis: a single threshold means breathy speech near the threshold toggles the gate (the 300 ms hold hides it at the tail but not at the onset).
- Energy-based detection after AGC is sensitive to AGC state; rnnoise's VAD is trained for speech vs noise.
Best practice (principles, not a single source): VAD with separate open/close thresholds, a hangover of 200-400 ms, and a short pre-roll/lookahead (10-30 ms) so the gate opens before the voiced part; ML VAD in preference to energy where it is cheap. WebRTC's own VAD (`common_audio/vad`) and AGC2's RNN VAD (`agc2/rnn_vad`) exist upstream, but are not exposed through the prebuilt. rnnoise already returns the VAD probability per frame (`rnnoise_process_frame` returns float; confirmed in third_party/rnnoise/src/denoise.c:499 `return vad_prob`) and we ignore it.
Proposed gate design (all inside flutter_input_gate.cc, plus a 20-30 ms delay line):
- open when (rnnoise_vad > ~0.6 OR level >= threshold), close when both false for hold ms; hysteresis 4-6 dB on the level path.
- delay line of 20 ms on the audio path (the decision runs on the undelayed signal), so the open ramp lands before the onset. 20 ms of added latency is negligible against network + jitter buffer.
- keep "Input sensitivity" as the level threshold so the UI contract does not change; VAD acts as an OR for opening, never closes a loud signal.
Risk: rnnoise VAD is only available when NS runs on 48k frames; fall back to energy-only otherwise. Test with recorded onsets (see P3 verification).
Discord/auto sensitivity: Discord's own doc says auto input sensitivity "can fall short with heavy background noise or large swings in speaking volume", so a fixed, visible meter threshold (what we have) is a defensible choice. A calibrate button (measure 3 s of ambient, set threshold 8 dB above) is a cheap UX win.

### 2.5 Platform specifics

Windows:
- Microsoft: by default the OS ducks other sounds when it receives a communication stream; default attenuation 80%, user-changeable in Sound > Communications ("Do nothing", mute all, reduce by 80/50%), fade 1 s (https://learn.microsoft.com/en-us/windows/win32/coreaudio/stream-attenuation and .../disabling-the-ducking-experience).
- `IAudioSessionControl2::SetDuckingPreference(TRUE)` lets an app opt ITSELF out of being ducked (it is for the other apps' sessions). It is not a way for a VoIP app to stop ducking others, so it is not our fix.
- libwebrtc WASAPI [src]: `core_audio_base_win.cc:357-359` picks `eConsole` for the default index and `eCommunications` for the communications index (our fork now forces console); but `core_audio_utility_win.cc:907` unconditionally sets `props.eCategory = AudioCategory_Communications` through `IAudioClient2::SetClientProperties`. MS: "tagging a stream as Communications will let Windows know to pause background music" (audio-signal-processing-modes). So the category, not just the role, is a plausible remaining ducking trigger. [unverified until tested]
- Same category also routes capture through the driver's Communications signal-processing mode, which on many OEM drivers inserts vendor AEC/NS/AGC. That is a double-processing source we cannot see. Raw mode (`AUDCLNT_STREAMOPTIONS_RAW`) is available only if `RawProcessingSupported` and requires no adaptive processing in the path (MS doc above); libwebrtc has it commented out.
- Windows has other categories: GameChat, Speech, Other. GameChat is the designed fit for in-game voice chat; whether it triggers ducking is not stated in the pages I read [unverified].
Recommendation: in the fork's Windows ADM patch, change the category to `AudioCategory_Other` (or GameChat) on both render and capture, and keep console role. Verify on the win11 VM that (a) music in another app is not ducked while a call runs, (b) AEC still has a render reference (it does: playout still goes through the ADM), (c) no OEM-effect change in capture quality. Fallback for users: document "Sound > Communications > Do nothing" in Voice settings help.

macOS:
- Our fork on macOS is stock flutter-webrtc/libwebrtc ADM, which uses the VoiceProcessingIO audio unit for I/O when AEC is on [unverified for this build]. VPIO ducks other app audio by default; since macOS 14 / iOS 17 `AVAudioInputNode.voiceProcessingOtherAudioDuckingConfiguration` lets an app set advanced ducking and a level (Apple docs: https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration , WWDC23 session 10235). LiveKit's Swift SDK exposes this as `isAdvancedDuckingEnabled` / ducking level on its AudioManager (third-party doc page found; Dart SDK parity [unverified]).
- Mute: `MicrophoneMuteMode` (voiceProcessing default plays the OS mute sound; inputMixer/restart silent) in livekit_client `audio/audio_manager.dart:408`. With `restart` Bluetooth headsets get audible route changes.

iOS:
- libwebrtc already disables its own NS on iOS because VPIO provides it (`webrtc_voice_engine.cc:139-143`). AGC runs fixed-digital. Session category/mode (playAndRecord + voiceChat) is managed by livekit/flutter-webrtc; our Runner only mentions the AVAudioSession in comments (VoiceCallReporter.swift:136). Needs on-device verification (OPEN-QUESTIONS already lists device-specific iOS items).

Android:
- `MODE_IN_COMMUNICATION` is the default in flutter-webrtc's `AudioSwitchManager` (android/.../audio/AudioSwitchManager.java:84) and our Telecom connection calls `setAudioModeIsVoip(true)` (platform/.../SlimmConnection.kt:47). Good.
- Capture source `VOICE_COMMUNICATION` "will for instance take advantage of echo cancellation or automatic gain control if available" (https://developer.android.com/reference/android/media/MediaRecorder.AudioSource). `AcousticEchoCanceler.isAvailable()` tells if the device has one (https://developer.android.com/reference/android/media/audiofx/AcousticEchoCanceler). Which of (hardware AEC, software AEC3) the Java ADM picks in this build [unverified]; device quality varies a lot, which is why Chrome and libwebrtc default to software AEC3 on many devices.

Linux (PipeWire/Pulse):
- libwebrtc's Pulse backend sets no `media.role` (grep of audio_device_pulse_linux.cc shows none). Consequences: no role-based ducking from module-role-ducking (not loaded by default, https://wiki.freedesktop.org/www/Software/PulseAudio/Notes/4.0), and no WirePlumber Bluetooth auto-switch to the headset profile, which keys off a Communication-role capture stream (https://gitlab.freedesktop.org/pipewire/wireplumber/-/merge_requests/365 and 309; setting `bluetooth.autoswitch-to-headset-profile`). So a Bluetooth headset on Linux will not switch to mSBC unless the user does it, which at least avoids the quality trap but also avoids having a mic on A2DP-only headsets.
- The role can be set per process with `PULSE_PROP="media.role=phone"` (KDE bug 362573 mentions the mechanism). Setting it would make the desktop treat us as a call. Not recommended until we want auto-switch; the trade-off is explicit (P10).
- The Pulse mixer manager calls `pa_context_set_source_volume_by_index` in `SetMicrophoneVolume` [src]. Whether our build's AGC calls it is unverified (section 1.3).
- System AEC alternative: PipeWire `libpipewire-module-echo-cancel` with the webrtc backend (https://docs.pipewire.org/page_module_echo_cancel.html). Not for us to ship; useful as a user workaround.

Web:
- `getUserMedia` honours `echoCancellation`, `noiseSuppression`, `autoGainControl` in Chromium, Firefox and Safari (MDN: https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackSupportedConstraints). Use `exact` only when failing is acceptable. Web is the one target with the best-maintained APM (the browser's), and it has no gate/dynamics from us.

### 2.6 Push-to-talk, mute latency, devices, Bluetooth
- PTT/mute cost: stopAudioCaptureOnMute=true closes and reopens the capture device. LiveKit documents the alternative: for fast silent toggling use `stopAudioCaptureOnMute: false` (audio_manager.dart:408-415). Trade-offs: the OS mic-in-use indicator stays on while muted (Discord and others also keep the mic open; privacy copy should say so), the ADM keeps running (small CPU), and the 300 ms gate hold state is not reset. With capture kept open the PTT press has only the network/encoder start-up delay.
- Bluetooth is where reopen hurts most: opening the mic on an A2DP headset forces the HFP/HSP switch (seconds, audible glitch, output drops to 8/16 kHz mono). Daily's write-up: HSP/HFP are low-bitrate low-delay codecs that "degrade audio quality significantly", also on the mic side, and "no amount of fancy codecs on the WebRTC side can work past that" (https://www.daily.co/blog/why-bluetooth-audio-quality-suffers-in-video-calls/). HFP 1.6 added wideband (mSBC, 16 kHz); LC3 is coming via LE Audio (Fraunhofer: https://iis.fraunhofer.de/en/ff/amm/communication/lc3). Keeping the stream open avoids repeated profile flips.
- Rnnoise is silently off at HFP rates (16 kHz) (see 2.2). If a headset is HFP, our "Strong" setting does nothing. UI should say so.
- Device switching: `AudioDeviceSwitching.selectInput` goes through `room.setAudioInputDevice`. Linux/Windows "default" is resolved once; the fork's Windows patch selects the default console endpoint by index at open time, so hot-plugging a new default device mid-call is not followed [unverified]. Check with a USB headset unplug during a call on both OSes (P11).
- Unmute race: `_trySetMicrophone` swallows errors and returns false; `setPushToTalkHeld` then leaves the previous state. Good defensive behaviour, but a failed reopen is silent to the user. With the stop-on-mute change this mostly disappears.

### 2.7 Other apps' sounds and AEC
- AEC3 cancels only what it is given as the render reference. In libwebrtc that is the call's own playout. Our app plays other audio through audioplayers/media_kit (notification chimes, module scene sounds, Jellyfin/media playback) outside libwebrtc's ADM [code: app/lib/src/audio/*, app/pubspec.yaml media_kit/audioplayers]. Those sounds reach the mic through the speakers uncancelled whenever the user is on speakers. This is expected for any app (Discord has the same limit), but it is worth a line in settings help: use headphones for watch-together. [inference; no authoritative source found, only third-party AEC3 ports describing the render-reference model.]

### 2.8 Measuring quality objectively
Fields (W3C webrtc-stats, https://www.w3.org/TR/webrtc-stats/):
- Receiver (`inbound-rtp`, kind audio): `totalSamplesReceived`, `concealedSamples`, `silentConcealedSamples`, `concealmentEvents`, `insertedSamplesForDeceleration`, `removedSamplesForAcceleration`, `jitterBufferDelay` / `jitterBufferEmittedCount` (average delay), `jitterBufferTargetDelay`, `packetsLost`, `packetsDiscarded`, `fecPacketsReceived`, `audioLevel`, `totalAudioEnergy`.
- Sender (`media-source`, kind audio): `audioLevel`, `totalAudioEnergy`, `echoReturnLoss`, `echoReturnLossEnhancement` (the latter two only when AEC reports them).
- Derived health numbers: concealment ratio = concealedSamples / totalSamplesReceived (>~5% is audible in my experience; no standard threshold exists - this is a rule of thumb, tune on real calls); mean jitter-buffer delay; `audioLevel` of the media-source after the gate to verify gating (docs/voice-input-gate.md already did this once by hand).
Objective scores:
- ViSQOL (https://github.com/google/visqol) gives MOS-LQO 1-5 from a reference and a degraded WAV, with a speech mode (`--use_speech_mode`; 16 kHz) and an audio mode (48 kHz). It is open source and scriptable; POLQA is licensed and needs certified tooling, so skip it.
- Loopback method: play a known speech WAV through a virtual sink/source into the client under test (e2e already has a fake-voice WAV path, scripts/e2e.sh), publish to a local livekit-server --dev, record the remote side, run ViSQOL on (reference, received). Run per config: APM only, + rnnoise, + gate, + dynamics, bitrate 24/32/48 kbps, with injected loss/jitter (tc netem).
- For the gate specifically, add a test with synthetic onsets (soft fricatives at -40..-55 dBFS) and assert onset energy preserved >= X ms.
- Add a debug "voice health" panel in the app reading `getStats` (Room stats via livekit_client) so owner reports come with numbers. Cheap and valuable.

## 3. Gap table (current vs best practice)
| Area | Now | Gap |
|---|---|---|
| Windows ducking | console role forced | stream still AudioCategory_Communications [src] |
| PTT / mute | stop+reopen capture | latency, BT flips, ducking restart |
| Gate | RMS, no lookahead/hysteresis | clipped onsets; AGC-dependent threshold |
| VAD | energy | rnnoise VAD probability discarded |
| Strong NS | rnnoise at 48k only, after WebRTC NS | double NS; silent no-op at 16/44.1k |
| AGC | AGC1 only | no AGC2; Linux mic-volume behavior unmeasured |
| Opus | 48 kbps, DTX, RED defaults | not tuned, not measured |
| Mobile / web | stock | no gate/dynamics; AEC path unverified on Android |
| Observability | none | no stats-based quality checks |

## 4. Prioritised proposals (impact vs effort; each is card-ready)

### P1 - Windows: stop tagging the call stream as Communications (high impact, medium effort)
- Problem: owner reports other apps get quieter during calls on Windows. The fork forced the console endpoint but libwebrtc still sets `AudioCategory_Communications`, which Microsoft says pauses/ducks background audio.
- Evidence: core_audio_utility_win.cc:907 `props.eCategory = AudioCategory_Communications` (upstream main); MS audio-signal-processing-modes ("tagging a stream as Communications will let Windows know to pause background music"); MS stream-attenuation (ducking by communication streams, default 80%).
- Change: in the fork's Windows ADM, set the category to `AudioCategory_Other` (try `GameChat` as the second experiment) for both render and capture; keep console role.
- Risk: loses OEM communications APO processing (good or bad per device); AEC delay estimate may shift; GameChat semantics undocumented for ducking. Fork patch must survive libwebrtc updates (it is a prebuilt; confirm the fork can actually rebuild libwebrtc or patch the shim, otherwise this needs the ADM wrapper layer - check before promising).
- Verify: win11 VM or real box, play music in another app, join a call, record system-mix level (loopback) before/after; also check Sound > Communications set to the default 80%; run a loopback ViSQOL before/after to catch AEC regressions.

### P2 - Keep the capture device open on mute and PTT (high impact, low effort)
- Problem: each PTT press/unmute reopens the device; on Bluetooth that flips profiles, on Windows it may restart the communications stream, and it adds start-up latency.
- Evidence: `AudioCaptureOptions.stopAudioCaptureOnMute` default true (livekit_client track/options.dart); `setMicrophoneEnabled` path in voice_session_tracks.dart:94; LiveKit's own note (audio_manager.dart:408) recommends `stopAudioCaptureOnMute:false` for fast toggling.
- Change: pass `stopAudioCaptureOnMute: false` in `AudioDeviceSwitching.roomOptions` (and in the per-call capture options if any). Add a settings sentence that the OS mic indicator stays on while muted. Confirm the muted track really sends silence/nothing (track.enabled=false) and that DTX keeps bandwidth near zero.
- Risk: privacy expectation (indicator stays lit); on iOS combine with `MicrophoneMuteMode.inputMixer` if the mute chirp matters.
- Verify: measure press-to-first-audio on the receiving side (e2e probe: key down timestamp vs first non-zero `audioLevel`), before/after, on Linux and Windows; Bluetooth headset manual test for no profile flip.

### P3 - Gate: lookahead, hysteresis, and rnnoise VAD (high impact, medium effort)
- Problem: voice activity feels delayed/clipped; soft word starts are cut because the gate opens only after a frame crosses the threshold.
- Evidence: flutter_input_gate.cc (open decision per frame, 5 ms ramp, no delay line); rnnoise returns the VAD probability and flutter_noise_suppressor.cc discards it; docs/voice-input-gate.md claims clipping <= 5 ms which holds only for loud onsets.
- Change: (a) 20 ms delay line on the audio path; decision on the undelayed copy; (b) open on `vad_prob > ~0.6 || level >= threshold`, close after hold when both are false, plus 4-6 dB level hysteresis; (c) expose nothing new in the UI at first; (d) update docs/voice-input-gate.md and the "start of a word" sentence.
- Risk: +20 ms capture latency; rnnoise VAD only at 48k (energy fallback); tuning needed to avoid keyboard clicks opening the gate (rnnoise VAD is low for clicks, which is the point).
- Verify: unit test of the gate with synthetic soft-onset signals (fricative-like noise bursts at -45 dBFS leading into a vowel) asserting the first N ms survive; recorded real onsets; e2e `getInputGate` and sender `media-source` level; subjective A/B with the owner.

### P4 - Do not stack two noise suppressors when Strong is on; show when Strong is inactive (medium impact, low-medium effort)
- Problem: WebRTC NS (fixed kHigh) + rnnoise in series, and rnnoise silently no-ops off 48k (HFP, 44.1k devices).
- Evidence: webrtc_voice_engine.cc (NS level hard-coded kHigh); flutter_noise_suppressor.cc `num_frames == kFrameSize`; docs/voice-input-gate.md ("at any other capture rate it passes audio through").
- Change: when Strong is selected, pass `noiseSuppression:false` in capture options (restart capture or use LiveKit's runtime `setAudioProcessingOptions`); surface `getInputGate.strongNoiseSuppression` in the settings row ("inactive: your mic runs at 16 kHz"); optionally resample to 48k inside the hook.
- Risk: without WebRTC NS, rnnoise at 48k must carry the load; compare on keyboard/fan recordings first. Switching capture options mid-call may glitch.
- Verify: ViSQOL + noise-reduction dB on a noisy-speech corpus; manual listening for musical noise.

#### Measured 2026-10-16
Offline A/B on espeak speech with synthetic noise, noise floor in dB (lower is better) and log-spectral distortion (lsd, lower is better).
Speech level was unchanged within 0.3 dB in every case.

| noise | webrtc only | A: webrtc + rnnoise | B: rnnoise only |
| --- | --- | --- | --- |
| fan at -38 dBFS | -63.4 dB, lsd 8.92 | -61.8 dB, lsd 16.34 | -66.3 dB, lsd 14.15 |
| keyboard at -36 dBFS | -46.1 dB, lsd 12.99 | -52.8 dB, lsd 19.59 | -61.6 dB, lsd 16.35 |
| hiss at -45 dBFS | -61.8 dB, lsd 11.25 | -61.6 dB, lsd 17.66 | -68.9 dB, lsd 15.75 |

rnnoise alone beats the stacked chain on every noise type, with about 2 dB less distortion.
Caveats: synthetic speech and noise, and the python webrtc-noise-gain APM at 16 kHz rather than the fork's own build.
Script and raw output are in `~/.slimm-scratch/tmp/mic-ab/`, not in the repo.

### P5 - Measure Linux AGC vs the system mic volume (medium impact, low effort, research-only first)
- Problem: possible that AGC moves the PulseAudio/PipeWire source volume (user's mic slider drifts, other apps affected).
- Evidence: our libwebrtc.so contains `pa_context_set_source_volume_by_index`; SetMicrophoneVolume calls it [src]; upstream main no longer feeds the analog level back from `AudioTransportImpl`, so behavior depends on the prebuilt's age [unverified].
- Change: first an experiment: `pactl subscribe` + `pactl get-source-volume @DEFAULT_SOURCE@` every second during a call with a loud and a quiet speaker, with `autoGainControl` true vs false. If the volume moves: pass `autoGainControl:false` on Linux when the gate+compressor are on (our compressor is not a leveler, so also consider a fixed pre-gain), or pin the source volume.
- Risk: removing AGC changes loudness for quiet users; compensate with fixed gain/limiter.
- Verify: before/after volume trace and a loudness measurement (LUFS/RMS) of the sent stream across speaker distance.

### P6 - Gate/dynamics outside Linux+Windows (medium-high impact, high effort)
- Problem: "mics pick up everything" is fixed only on 2 of 6 platforms.
- Evidence: input_gate.dart `supportsInputGate` = linux||windows; docs say web/macOS/iOS/Android keep the indicator-only slider.
- Options ranked by effort: (1) Dart-level mute-by-VAD on those platforms using the SFU/local level and `track.enabled` (adds latency, coarse); (2) LiveKit `TrackProcessor` (`AudioCaptureOptions.processor`) on mobile if the Dart SDK supports a native audio processor [unverified]; (3) native Android/iOS processing hook in the fork (the libwebrtc iOS/Android builds expose capture post-processing too [unverified]). Web: Web Audio worklet gate is feasible.
- Risk: large; each platform has its own audio session semantics. Start with web (worklet) or defer; consider whether owner use is mostly desktop first.
- Verify: same synthetic-onset and `media-source` level tests per platform.

### P7 - Voice-health telemetry and an objective test (medium impact, medium effort)
- Problem: quality is judged by ear.
- Evidence: no getStats usage in client/packages/rtc besides the fork's note; W3C stats fields in 2.8.
- Change: (a) a debug panel / log line with concealment ratio, mean jitter-buffer delay, packetsLost/discarded, sender audioLevel, echoReturnLoss; (b) an e2e job variant that publishes the fake-voice WAV, records the receiver and computes ViSQOL for a few configs (advisory, same posture as e2e).
- Risk: ViSQOL setup (bazel build or pip wheel); keep it out of required checks.
- Verify: known-bad input (netem 10% loss) must show a lower score and higher concealment ratio than clean.

### P8 - Explicit Opus publish options (medium impact, low effort, measure-first)
- Problem: we run music-oriented defaults (48 kbps, RED) for speech.
- Evidence: livekit_client options.dart/audio_encoding.dart; Opus wiki (24 kb/s fullband for VoIP); RFC 7587 params.
- Change: set `AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 32000), dtx: true, red: true)` as an experiment; keep 48k as the high-quality option if the owner prefers; do not touch FEC (no Dart knob).
- Risk: lower fidelity for singing/music in canvas voice; RED+low bitrate balance.
- Verify: ViSQOL (speech mode and audio mode) across bitrates under netem; owner listening.

### P9 - Advanced voice processing toggles (low-medium impact, low effort)
- Problem: no way to turn off AEC/AGC/NS individually when a particular headset/driver misbehaves; support cases need a lever.
- Evidence: Discord exposes separate toggles; livekit_client exposes `setAudioProcessingOptions` and `getAudioProcessingState()` (audio_manager.dart).
- Change: a collapsed "Advanced" section: echo cancellation, noise suppression (Standard), auto gain control; defaults on; apply live. Follow settings-copy rules (short label, one-sentence description).
- Risk: more ways to misconfigure; keep behind an expander.
- Verify: toggle live in a call and read `getAudioProcessingState()` and `getStats` to confirm effect.

### P10 - Linux: decide on `media.role` (low-medium impact, low effort, decision needed)
- Problem: no role means no Bluetooth auto-switch and no semantic routing.
- Evidence: audio_device_pulse_linux.cc sets no media.role; WirePlumber autoswitch logic keys on Communication role capture streams.
- Change: option A leave as is (no BT mic on A2DP-only headsets unless user switches profile); option B set `PULSE_PROP=media.role=phone` in the launcher for calls only. Owner/product decision, not a silent change.
- Risk: B may trigger role-ducking where users enabled it, and BT profile flips; A leaves users unable to use some BT mics without manual action.
- Verify: Bluetooth headset on Fedora/PipeWire with both options.

Decision 2026-10-26 (owner): try option B behind a hidden flag, default off.
- Flag: the process environment variable `SLIMM_CALL_MEDIA_ROLE=1`, the same kind of hidden switch as `SLIMM_NO_UPDATE_CHECK`; it is not in the settings UI.
- Mechanism: `applyCallMediaRole()` (rtc `call_media_role.dart`) runs first in `main()` and exports `PULSE_PROP=media.role=phone` with libc `setenv` over dart:ffi, merged with any `PULSE_PROP` the user already set.
- Why not pactl or pw-cli: neither can add a property to another client's stream, and the plugin fork needs no change.
- Why in `main()`: libpulse reads `PULSE_PROP` once, in `pa_context_new`, so setting it after libwebrtc's context exists does nothing (tested with a small C program against this box's PipeWire).
- Why not per call: libwebrtc holds one context for the process, so the role cannot be scoped to a single call; only libwebrtc's own capture and playout streams are tagged as a call, but any other Pulse context opened later in the process (media_kit, GStreamer) inherits it too.
- Verified here: a Dart process that called `hostSetenv` and then opened a Pulse capture stream showed `media.role = "phone"` in `pactl list source-outputs`, and the same process before the call showed none.
- Not verified: the full desktop app with a real call, and a Bluetooth headset auto-switching; that needs the owner's hardware.

### P11 - Hot-plug and default-device following (medium impact, low effort test first)
- Problem: unknown behavior when the default mic changes mid-call.
- Evidence: fork selects the default console endpoint at open time (commit 9c318c1); selectInput in audio_device_switching.dart.
- Change: test first; if broken, listen for device-change events (`AudioDevices.onChange`) and call `selectInput(null)` when the user chose "system default" and the default changed.
- Verify: unplug/replug USB headset on Windows and Linux during a call; assert capture continues and meter moves.

## 5. Things I could not confirm (do not state as fact)
- The libwebrtc version of the prebuilt and therefore whether its AGC drives the OS mic volume.
- Whether `AudioCategory_GameChat` avoids ducking.
- Discord/Zoom/Teams/Meet VAD and gating internals (no primary sources found; Krisp use by Discord is documented by Discord).
- Which Android echo canceller (hardware vs software) the Java ADM selects in flutter-webrtc 1.6.0.
- Whether livekit_client 2.10.0 on desktop honours `setAudioProcessingOptions` through our fork.

## 6. Measured 2026-10-18: Strong at any mic, and what the input bar shows

The first measurements of the real Linux plugin on this Fedora 44 and PipeWire box, in a call against a local `livekit-server` 1.10.1, received by a second participant.
Everything here is reproducible with the rig described under "How it was measured".

### 6.1 What the plugin sees on Linux

Virtual sources at 16000, 22050, 44100, 48000 and 96000 Hz, mono, stereo and four channels, all reached the capture chain as mono 48 kHz, 480-sample frames, one `Process` call per 10 ms (200 calls in 2 s).
PipeWire converts rate and channel count before libwebrtc's ADM sees the stream, so on Linux the resampling path in `flutter_noise_suppressor.cc` is never taken.
It matters where the ADM hands the audio processing module a non-48 kHz mic: Windows (WASAPI shared mode, Bluetooth hands-free at 16 kHz) and libwebrtc's own 16 and 32 kHz internal rates.
That path was checked on its own instead, with the same noisy-speech file resampled to each rate and run through `NoiseSuppressor` frame by frame (6 s of fan and keyboard, 16 s of speech, 6 s of fan and keyboard):

| rate | noise before speech (dBFS) | speech (dBFS) | envelope match | soft-tail change (dB) |
|---|---|---|---|---|
| 8000 | -96.3 | -21.5 | 0.884 | -10.5 |
| 16000 | -96.4 | -21.5 | 0.952 | -4.7 |
| 32000 | -96.3 | -21.5 | 0.959 | -3.8 |
| 44100 | -96.4 | -21.5 | 0.959 | -3.6 |
| 48000 | -126.2 | -21.5 | 0.957 | -4.2 |
| 96000 | -96.3 | -21.5 | 0.959 | -3.9 |

Strong is running at every rate (2816 of 2816 frames), speech level is unchanged, and the added delay is 0.4 to 2.3 ms (18 samples at the lower rate, 35 at 96 kHz).
8 kHz only differs because a 4 kHz band carries less of the speech.
The rest is not measurable below -90 dBFS, which is digital silence for this purpose.

Odd mics, 48 kHz, offline through the same stage (input to output):

| mic | noise before speech | speech level | envelope match |
|---|---|---|---|
| speech 23 dB too quiet | -62.7 to -116.1 | -44.2 to -44.5 | 0.886 to 0.936 |
| DC offset of 8% | -21.9 to -116.7 | -18.5 to -21.5 | 0.684 to 0.958 |
| 14 dB too hot, clipped | -25.8 to -106.9 | -8.0 to -8.3 | 0.890 to 0.948 |
| 50 Hz hum at -30 dBFS | -38.6 to -101.8 | -27.0 to -27.5 | 0.795 to 0.941 |

### 6.2 Off, Standard and Strong in a call

Input: a 28 s file with 6 s of fan, hum and keyboard clicks (-40 dBFS RMS), 16 s of two espeak and flite sentences at -22 dBFS over the same noise, then 6 s of the noise again.
Measured on the receiving side, input gate off, so this is suppression alone.
"Noise between words" is the level in the pauses inside the utterance.
The unprocessed file reads -39.7 / -40.0 / -41.3 / -21.2 with envelope match 0.886.
Every cell is one run, and the noise cells are an average level over a few seconds, so differences of 1 to 3 dB are not meaningful.

| mic rate | channels | mode | noise before speech (dBFS) | noise after speech (dBFS) | noise between words (dBFS) | speech (dBFS) | envelope match | Strong running |
|---|---|---|---|---|---|---|---|---|
| 16000 | 1 | Off | -34.8 | -38.2 | -37.1 | -15.6 | 0.871 | no |
| 16000 | 1 | Standard | -43.9 | -48.4 | -43.8 | -14.8 | 0.908 | no |
| 16000 | 1 | Strong | -76.4 | -103.7 | -54.6 | -14.5 | 0.95 | yes |
| 22050 | 1 | Off | -33.6 | -37.9 | -36.9 | -15.7 | 0.877 | no |
| 22050 | 1 | Standard | -41.9 | -46.9 | -44.3 | -14.8 | 0.925 | no |
| 22050 | 1 | Strong | -92.3 | -107.2 | -54.5 | -15.7 | 0.952 | yes |
| 44100 | 1 | Off | -33.3 | -37.9 | -36.7 | -15.6 | 0.873 | no |
| 44100 | 1 | Standard | -41.5 | -46.8 | -44.5 | -14.8 | 0.924 | no |
| 44100 | 1 | Strong | -101.3 | -97.9 | -56.3 | -14.5 | 0.957 | yes |
| 48000 | 1 | Off | -34.6 | -38.0 | -37.3 | -15.6 | 0.88 | no |
| 48000 | 1 | Standard | -41.5 | -47.4 | -44.1 | -14.8 | 0.925 | no |
| 48000 | 1 | Strong | -77.5 | -85.5 | -54.1 | -15.7 | 0.952 | yes |
| 96000 | 1 | Off | -33.3 | -37.7 | -36.7 | -15.6 | 0.881 | no |
| 96000 | 1 | Standard | -41.7 | -46.8 | -44.0 | -14.8 | 0.924 | no |
| 96000 | 1 | Strong | -82.9 | -95.8 | -51.6 | -15.7 | 0.951 | yes |
| 16000 | 2 (same on all) | Off | -34.6 | -36.1 | -36.5 | -15.0 | 0.868 | no |
| 16000 | 2 (same on all) | Standard | -43.4 | -48.3 | -44.3 | -14.8 | 0.923 | no |
| 16000 | 2 (same on all) | Strong | -106.8 | -102.2 | -55.1 | -14.5 | 0.953 | yes |
| 44100 | 2 (same on all) | Off | -34.5 | -35.9 | -37.1 | -15.0 | 0.882 | no |
| 44100 | 2 (same on all) | Standard | -41.3 | -46.8 | -44.6 | -14.8 | 0.921 | no |
| 44100 | 2 (same on all) | Strong | -71.6 | -71.3 | -54.7 | -15.1 | 0.953 | yes |
| 96000 | 2 (same on all) | Off | -34.5 | -36.1 | -36.7 | -15.0 | 0.879 | no |
| 96000 | 2 (same on all) | Standard | -41.6 | -47.6 | -44.7 | -14.8 | 0.924 | no |
| 96000 | 2 (same on all) | Strong | -84.1 | -99.5 | -55.4 | -15.1 | 0.957 | yes |
| 44100 | 2 (first only) | Off | -40.7 | -38.1 | -38.4 | -16.5 | 0.876 | no |
| 44100 | 2 (first only) | Standard | -48.6 | -49.7 | -48.2 | -16.5 | 0.926 | no |
| 44100 | 2 (first only) | Strong | -86.3 | -99.8 | -54.9 | -16.3 | 0.95 | yes |
| 48000 | 4 (same on all) | Off | -34.7 | -38.0 | -36.7 | -15.6 | 0.878 | no |
| 48000 | 4 (same on all) | Standard | -42.0 | -48.1 | -43.8 | -14.8 | 0.926 | no |
| 48000 | 4 (same on all) | Strong | -84.1 | -90.1 | -55.1 | -15.1 | 0.958 | yes |
| 48000 | 4 (first only) | Off | -46.7 | -43.0 | -44.2 | -22.0 | 0.875 | no |
| 48000 | 4 (first only) | Standard | -54.6 | -55.0 | -53.8 | -22.0 | 0.927 | no |
| 48000 | 4 (first only) | Strong | -103.6 | -97.9 | -62.4 | -22.1 | 0.953 | yes |

What it shows:

- Off leaves the fan and clicks 5 dB louder than the input, because libwebrtc's gain control raises the quiet parts. Standard takes about 8 dB off. Strong takes the noise to the point where the receiver hears digital silence (-70 to -107 dBFS), and between words it leaves -52 to -56 dBFS against -44 for Standard.
- Speech level is the same in all three (-14.5 to -15.7 dBFS after gain control), and Strong's envelope follows the clean speech better (0.95 against 0.92 and 0.87).
- The rate and the channel layout made no difference to Strong, as 6.1 predicts. A four-channel or left-only source comes out 1 to 7 dB quieter in every mode because PipeWire averages the channels into the mono stream.
- Strong was running in every run (the app's `strongNoiseSuppression` flag read true on every poll), so the "not running" note and the fallback to Standard stay quiet on this box.

The soft-tail column in the raw output (level change of the quietest word endings) was within 4 dB of the input for Strong and Standard and about +10 dB for Off, where noise fills the tails; no run clipped (0.000% of samples at full scale).

### 6.3 What the input bar shows

The bar is `levelDb` from `getInputGate`: the level of the frames the gate decides on, which is after libwebrtc's own suppression and gain control and after rnnoise, before the gate.
So it is already the post-suppression signal, not the raw capture.
Measured with the gate off, the bar tracked the received level with a correlation of 0.88 to 0.92 for Off, Standard and Strong.

What did not line up was the bar's smoothing, not its source.
The old meter rose instantly and fell 1.5 dB per frame from the last peak.
A single click at -25 dBFS therefore kept it above a -50 dBFS line for 16 frames while the gate had looked at one frame, and the 300 ms hold keeps the gate open long after the bar has dropped.
Noise only (fan and 5 clicks a second), default -50 dBFS line, gate on, over 18 s:

| mode | line | bar over the line | gate open | receiver hears something |
|---|---|---|---|---|
| Standard | -50 | 36% | 80% | 87% |
| Standard | -40 | 17% | 68% | 74% |
| Strong | -50 | 0% | 0% | 0% |
| Strong | -40 | 0% | 0% | 0% |

With Standard, clicks open the gate and the hold keeps it open, so the bar sat under the line for most of the time the audio was going out.
Strong with the fan and keyboard never opened it, and the bar never crossed the line.

Two changes (fork 61d8b3e and this repo):

- `getInputGate` now returns the loudest frame since the previous poll, which is exactly what the threshold test compares, with no decay. Measured against the sent audio in 50 ms windows with Standard and the same noise: the bar agreed with the received signal being over the line in 84% of windows before and 89% after, and bar-over-the-line-while-no-frame-was-over dropped from 14% to 10% (the rest is codec and alignment jitter in this measurement).
- The settings bar draws in the accent colour while the gate is open and in a neutral one while it is closed, so the hold is visible instead of looking like the gate ignoring the bar. The speaking ring was already the gate's own state.

### How it was measured

`livekit-server` 1.10.1 on its own ports, a small Flutter Linux app that joins with the real `VoiceSession` (or a bare room with libwebrtc suppression off, for Off) and logs `getInputGate` every 50 ms, a null sink per rate and channel count with `PULSE_SOURCE` pointing the app at its monitor, and a Python participant that records the track.
Speech is espeak-ng and flite, not a recorded voice, so numbers for a real voice will differ a little.
Alignment of the received file to the input is by cross-correlation of the energy envelopes.
Every PipeWire module was unloaded afterwards and the default devices were never changed.

## 7. Source list
- WebRTC APM header: https://webrtc.googlesource.com/src/+/refs/heads/main/api/audio/audio_processing.h
- WebRTC voice engine (ApplyOptions): https://webrtc.googlesource.com/src/+/refs/heads/main/media/engine/webrtc_voice_engine.cc
- WebRTC Windows core audio: https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_device/win/core_audio_utility_win.cc and core_audio_base_win.cc
- WebRTC Pulse ADM: https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_device/linux/audio_device_pulse_linux.cc and audio_mixer_manager_pulse_linux.cc
- LiveKit noise/echo cancellation: https://docs.livekit.io/transport/media/noise-cancellation/
- Discord/Krisp: https://discord.com/blog/clean-up-the-noise-with-krisp ; input sensitivity: https://support.discord.com/hc/en-us/articles/211376518
- Microsoft: https://learn.microsoft.com/en-us/windows/win32/coreaudio/stream-attenuation ; .../disabling-the-ducking-experience ; .../using-the-communication-device ; https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nf-audiopolicy-iaudiosessioncontrol2-setduckingpreference ; https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/audio-signal-processing-modes
- Apple: https://developer.apple.com/documentation/avfaudio/avaudioinputnode/voiceprocessingotheraudioduckingconfiguration ; WWDC23 10235
- Android: https://developer.android.com/reference/android/media/MediaRecorder.AudioSource ; https://developer.android.com/reference/android/media/audiofx/AcousticEchoCanceler
- PipeWire echo cancel: https://docs.pipewire.org/page_module_echo_cancel.html ; WirePlumber autoswitch: https://gitlab.freedesktop.org/pipewire/wireplumber/-/merge_requests/365 ; PulseAudio role ducking: https://wiki.freedesktop.org/www/Software/PulseAudio/Notes/4.0
- Opus: https://wiki.xiph.org/Opus_Recommended_Settings ; https://www.rfc-editor.org/rfc/rfc7587.html
- rnnoise: https://github.com/xiph/rnnoise/blob/main/include/rnnoise.h
- WebRTC stats: https://www.w3.org/TR/webrtc-stats/ ; MDN inbound-rtp: https://developer.mozilla.org/en-US/docs/Web/API/RTCInboundRtpStreamStats ; constraints: https://developer.mozilla.org/en-US/docs/Web/API/MediaTrackSupportedConstraints
- ViSQOL: https://github.com/google/visqol
- Bluetooth: https://www.daily.co/blog/why-bluetooth-audio-quality-suffers-in-video-calls/ ; https://iis.fraunhofer.de/en/ff/amm/communication/lc3
- Our code: client/packages/rtc/lib/src/{voice_session.dart,audio_device_switching.dart,input_gate.dart,voice_session_input_gate.dart,voice_session_tracks.dart}; client/packages/app/lib/src/features/voice/providers/voice_controller_input.dart; docs/voice-input-gate.md; fork ~/.slimm-scratch/webrtc/flutter-webrtc/common/cpp/src/{flutter_capture_chain,flutter_noise_suppressor,flutter_input_gate,flutter_voice_dynamics,flutter_media_stream,flutter_webrtc_base}.cc

## Listener-side mute and volume (moved from the code, 2026-10-17)

What one listener has done about what reaches their own ears.

Three axes that all end in the same place, so they live together rather than as three fields on the session: deafen everyone, silence one person, and turn one person up or down.
Split out of `voice_session.dart` when the third took that file past the 500-line ceiling.

**All of it is local and none of it is announced.** The SFU is never told, so somebody who has been muted or turned down cannot learn that they were - the same reason blocking is silent.
Anything room-visible (a moderator's timeout, a kick) is a server call, not this.

**It is applied by reapplication, not by event.** [applyTo] runs on every room event rather than only when a control moves, which is what keeps a participant who joins mid-call, or whose track resubscribes after a network blip, in the state this listener chose.
Gain needs that more than muting does: it lives on the platform track object, so a resubscribed track arrives back at full volume with nothing to say so.

**What it does not do is push a value a track already has.** The caller fires this from a catch-all room-event listener, and one of those events is `ActiveSpeakersChanged`, which arrives several times a second for as long as anybody is talking.
Every push is a real platform round trip - flutter_webrtc's `enabled` setter invokes `mediaStreamTrackSetEnable` with no equality check of its own, and for an audio track it also fires that track's `onMute`/`onUnMute` - so reapplying unconditionally spends a method channel per remote track per event to set values that are already set.

**What it skips on is the track's own state, not a memory of what was asked for**, and the distinction is the whole safety of the thing.
Whether a track is silenced is read back from it every time, which costs nothing: flutter_webrtc keeps `enabled` in a local field its setter maintains.
So if anything at all leaves a track in a state this listener did not choose, the next event sees it and corrects it, exactly as unconditional reapplication did.

That matters because something does.
`Track.enable`/`disable` do nothing when the track is not `_active`, silently and without throwing, and `addSubscribedMediaTrack` emits `TrackSubscribedEvent` *before* it awaits `track.start()`, which itself awaits `startCapture()` before setting `_active`.
The emitter is asynchronous, so this runs on a resubscribed track while it is still inactive, the push is dropped with nothing said, and `RemoteTrack.start()` then calls `enable()` of its own accord.
A cache that trusted the call would leave a muted participant audible for the rest of the call; reading the state back means the next event fixes it.

Gain is the exception, because there is nothing to read it back from - flutter_webrtc offers no getter.
[_applied] remembers it, keyed on the platform track object rather than any id.
A resubscribe reuses the publication and its sid, so an id-keyed cache would report a hit and skip the reapplication that exists precisely to catch a track that came back at source volume.
It does not reuse the object: `addSubscribedMediaTrack` builds a new `RemoteAudioTrack` around the new `MediaStreamTrack`, so a resubscribed track misses, which is the point.
The entry is also only written when the enable that precedes it can be seen to have landed.

## Update 2026-10-18: releasing a muted capture, and what a deafened listener receives

Silence on the receive side is now two calls: the media track's `enabled` flag for an instant local result, and the publication's `disable()`, which sends `UpdateTrackSettings(disabled)` so the SFU stops forwarding (livekit_client 2.10.0, `remote.dart`).
It keeps the subscription and needs no renegotiation, so the "drops the subscription" comments that said otherwise are gone.

A mute keeps the capture for `kMicReleaseGrace`, then stops it and reopens it on the next unmute.
Push to talk keeps it open, and a phone releases it the moment the app is backgrounded.

Measured on Fedora with PipeWire, a bare livekit_client room with the gate and rnnoise on: libwebrtc's desktop engine already drops the PulseAudio source-output within 0.6 s of any mute, so on Linux the release changes nothing visible and costs the same ~25 ms to come back.
The release matters where the track holds the device on its own: the web (the browser keeps the stream live while `enabled` is false) and the platforms where livekit_client starts the recording itself (iOS, macOS, Android), which is why `LiveKitMicPort.release` also asks the plugin to stop the recording there.

## Update 2026-10-19: push to talk readies the device at join

Push to talk already kept an open capture across presses, but a call that joined with push to talk on published no microphone track at all, so the first key down opened the device and published in one go.
Now such a join (and turning push to talk on in a call with no track) opens the capture and publishes it muted, with the media track disabled before publishing so nothing is sent in the gap.
The policy is: push to talk keeps the device open for the whole call, an ordinary mute keeps the 15 s grace and then releases it so the OS indicator goes off, and turning push to talk off starts that grace.
A muted join without push to talk still opens nothing.
The cost is that the OS microphone indicator stays on for the whole of a push-to-talk call; the Voice setting says so.
No "release when muted" toggle was added: the reopen after the grace measured at no more than a first publish costs, and push to talk is already the opt-in for staying ready.

Measured in headless Chrome against a local LiveKit 1.10.1 with livekit-client 2.15.0 (the web path, a proxy for Flutter web; native desktop was not measured), 15 runs each, time from the unmute call until the receiving page sees audio-sized packets:

| Case | p50 | p95 |
|---|---|---|
| Unmute, device kept open | 52 ms | 53 ms |
| Unmute, device released and reacquired | 52 ms | 53 ms |
| First press, nothing published (before) | 143 ms | 144 ms |

Chrome's fake capture device reopens instantly, so the reacquire row says nothing about real hardware or Bluetooth; the win measured here is the first publish, and it grows with the round trip to the SFU.
The probe is `~/.slimm-scratch/tools/mic-open-probe/probe.mjs`.

## Update 2026-10-26: is a low-latency mode worth building

The owner asked for one switch that turns processing off and uses small Opus frames, built only if the gain is measurable end to end.
It was not built, for the reasons below.

### Mouth to ear, processing on and off

Measured with the `voice latency` scenario (`scripts/lib/e2e_voice_latency.py`) in two headless Chromes through a local LiveKit 1.10.1, clean network, 60 s per run, chirps stamped on one epoch clock at the sender's microphone tap and the receiver's decoded track.
Each run gives one median per direction; the table lists both.
"On" is Chrome's own echo cancellation, noise suppression and AGC (`E2E_VQ_PROCESSING=1`), "off" is all three disabled.

| Processing | Frame request | Run 1 (A to B / B to A) | Run 2 (A to B / B to A) |
|---|---|---|---|
| off | default | 56.3 / 47.9 ms | 55.4 / 60.4 ms |
| on | default | 47.0 / 49.5 ms | 55.0 / 49.9 ms |
| off | ptime 10 | 56.9 / 50.1 ms | |
| off | ptime 20 | 62.4 / 59.5 ms | |
| on | ptime 10 | 53.5 / 53.9 ms | |
| on | ptime 20 | 47.2 / 49.0 ms | |

Two identical runs differ by up to 12 ms, which is larger than any difference between processing on and off, so the browser measurement shows no gain from turning processing off.
Packets received were 3150 in 60 s in every row, which is 50 packets per second or 20 ms frames, so the ptime request changed nothing and the ptime rows only repeat the baseline.
Chrome ignores `ptime` in `RTCRtpEncodingParameters` here.

### Why there is no frame-size half

There is no 10 ms frame option to switch on.
livekit_client has no ptime or frame duration in `AudioPublishOptions` (pinned at 2.13.1; 2.10.0 has none either), and the flutter-webrtc fork has no ptime field.
Opus packetization on the desktop engine is therefore fixed at the libwebrtc default of 20 ms.
The most a 10 ms frame could save is one frame of packetization delay, which is the size of the run-to-run noise above.

### Processing on desktop

The desktop capture chain adds little on its own: rnnoise adds 0.4 to 2.3 ms (section 6), and the input gate hold only delays closing, never opening.
Turning libwebrtc's processing off on desktop needs a mic track restart (the runtime `setAudioProcessingOptions` throws with the fork), at the price of echo for anyone on speakers.
That trade is not worth a gain that is inside the noise, so the switch stays unbuilt until a real desktop measurement says otherwise.
The desktop number was not measured here: the harness drives browsers only.

### P9 and P8 follow-ups

P9 (individual echo, noise and gain toggles) did not fall out of this work, because no capture-option plumbing was added.
The same restart path as Strong (`CaptureNoiseSuppression`) would carry it, but it still needs a desktop-side verification of `getAudioProcessingState()` that this run did not do.
The 32 kbps experiment was not repeated with the corpus scorer.
The earlier synthetic-clip runs of the `bitrate32-sender` variant against the 48 kbps baseline scored similarity 0.958 to 0.975 against 0.971 to 0.980, with more level bursts under 5% loss (22 against 7 for one side), so 32 kbps is no better and the default stays at 48 kbps with DTX off.

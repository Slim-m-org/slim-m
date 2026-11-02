<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Voice, stream and call audit - slim-m

Audited tree: origin/main at 3cce41eee, checkout /home/npc/.slimm-scratch/wt-audit-voice.
Audit date: 2026-11-01 to 2026-11-02.
Method: seven readers mapped the pipelines, one reader ran the local harness, and independent verifiers (correctness, impact, fix) then checked every finding.
Evidence tags: VERIFIED-SRC means the code path was read end to end, VERIFIED-RUN means it was measured, SUSPECTED means plausible but not confirmed.
Severities below are the verifier-corrected ones, not the first-pass ones.

## 1. Verdict

Call audio is very good where it has been measured.
On the web harness a clean call scores ViSQOL 4.39 to 4.42 with zero concealment and 53 to 63 ms mouth-to-ear.
5% loss with 30 ms jitter still scores 4.38 to 4.39 at 117 ms (the 2026-10-19 note had 4.14 to 4.17 at 151 to 162 ms), while prod LiveKit sits at 0.3% CPU with all 14 recent sessions on direct UDP.
The settings behind that (RED on, DTX off, 48 kbps) are correct and should not be touched.
What is not known is how it sounds where the friends actually are: 12 of 14 recent prod sessions were Windows (from only two users), none were iPhone, and every quality number comes from Chrome's libwebrtc with the app's own mic processing forced off.
By code reading, the weak spots are not codec settings but visibility, recovery and a few unproven desktop paths.
An SDK reconnect is invisible, a mid-call camera quality change never applies, and desktop screen capture ignores the requested size, so layer sizes and the admin cap may not match the real frames (unmeasured).
Data saver does nothing for shares, and shared audio is mono.
The three changes that would move quality most are:
- (1) measure and, if confirmed, fix the desktop screen-share size and layer mismatch on real Linux and Windows hardware;
- (2) show LiveKit reconnects in the call (display only, no new recovery layer);
- (3) decide the Space noise suppression default (Strong) and make Windows and iPhone field data cheap to collect with a diagnostics export.

## 2. Measured today

Setup: local e2e stack, LiveKit v1.10.1 container, two headless Chromes, netem on SFU egress, livekit_client 2.13.1, server 0.104.0, load average about 13 on a 32 core box.
Raw logs: /home/npc/.slimm-scratch/tmp/audit-voice/measure/.
n is one 45 s recording per side per profile with one netem draw, so differences below about 0.1 MOS or 10 ms are noise.

| Measure | Result (side a / side b) | Earlier note (2026-10-19) | Meaning |
|---|---|---|---|
| Clean ViSQOL | 4.42 / 4.39 | 4.41 | Call path is transparent. |
| Clean DNSMOS ovrl | 3.36 / 3.42 (delta +0.04 / 0.00) | - | No audible damage. |
| Clean concealment, jitter buffer | 0 samples, 31 to 33 ms | 33 ms | Adaptive buffer is already low. Leave playout alone. |
| Clean mouth-to-ear (chirp median) | 62.9 / 59.1 ms (min 52.9, p95 up to 63) | 54 to 58 ms | Browser decoded track only. Excludes OS capture and playout buffers. |
| loss 5% + 30 ms jitter ViSQOL | 4.39 / 4.38 | 4.14 to 4.17 | RED removed the loss damage. The cause of the gain is not stamped anywhere (see M3). |
| loss5-jitter30 concealment | 4178 samples in 5 events, 2481 in 4; 121 / 107 packets lost | - | Isolated loss is concealed cleanly. |
| loss5-jitter30 mouth-to-ear | 117.0 / 117.1 ms (p95 121 / 118), buffer 65 to 70 ms | 151 to 162 ms | About 35 ms better, almost all jitter buffer. |
| Burst loss ViSQOL | 4.22 / 3.98 | 3.9 to 4.05 rows | Weakest profile. See A8. |
| Burst anomalies | a: 1 dropout, 1 level burst. b: 2 dropouts, 2 level bursts, 1 static | 8 to 31 bursts summed over 4 recordings | Smaller than before, still audible in the worst case. |
| Burst concealment | 54455 samples / 37 events, 80416 / 50 events; 117 / 163 lost; buffer 29 ms | - | Receiver conceals instead of buffering (profile has no jitter, so this comparison is confounded). |
| Burst mouth-to-ear | 103.6 / 108.4 ms (p95 115) | 112 to 133 ms | Fine. |
| 10 s stats dump, clean | 476 packets, 0 lost, buffer 31.3 ms vs target 20, 80.1 kbps, packetsDiscarded 476 | - | Discards equal received, probably RED duplicates (SUSPECTED). |
| App health probe (60 s, clean) | conceal 0%, buffer 37 to 39 ms, rtt 0 to 1 ms, sent 68 kbps | - | The product's own sensor agrees with the harness. |
| Join to first remote audio | warm p50 254 ms (248 to 266), cold 420 to 690 ms | warm about 280 ms | Zero-RTT loopback. The 1.5 s target passes trivially (see M7). |
| Screen share 1080p30 (viewer 2560 px) | 1920x1080, 23.7 fps, 1.56 Mbps, 5 freezes | 28.6 fps, 3.05 Mbps (2026-10-18) | Software canvas source on a busy box. Not a verdict on real capture. |
| Screen share 1080p60 | 28.3 fps, 1.46 Mbps, 6 freezes | - | Same caveat. 60 fps is the tier prod users pick. |
| Screen share 720p30 / 1440p30 / 2160p tier on a 1080p screen | 26.3 fps / 13.1 fps / 23.3 fps, nothing published above the 1080p source | - | fitScreenShare does not publish above the source (web path). |
| Share sender stats | declared encodings reach the encoder (q 1.25M + h 5.0M at 1080p30); qualityLimitationDurations "bandwidth" 19 to 30 s of 44 s on loopback | - | Loopback BWE ramp plus a mostly static synthetic source. Bitrate could not be used to judge sharpness. |
| Prod SFU, 24 h | 0.29% CPU, 58.6 MiB of 512 MiB, 0 restarts, 42 WARN, 0 ERROR | - | Nowhere near limits. |
| Prod sessions, 24 h | 14 of 14 udp4 host pairs, 0 relay, 0 tcp; connectTime 1.14 to 1.27 s for 12 Windows sessions (2 users), 258 and 304 ms for 2 Linux LAN sessions | - | UDP works. Windows join is about 4x slower than Linux (cause not shown to be RTT). |
| Prod tracks, 24 h | 13 microphone (all audio/red, TF_NO_DTX), 8 screen share (all 1080p60 tier, q 960x540 2 Mbps, h 1920x1080 8 Mbps), 0 camera, 0 share audio | - | Publish options confirmed live. Camera is unused today. |

Not measured in any run: real desktop mic chain, Windows, iPhone, echo, native receive path, real screen-share encode, uplink loss, TURN relay, more than 3 participants, reconnect after 2026-10-19.

## 3. Ranked plan

Order inside each group is quality impact per effort, highest first.
Items that are one change were merged.
"Lens doubts" lists where a verifier rated the item lower or refuted part of it.
Lounge UX and canvas items are in sections 6 and 7.

### 3.1 Audio

**A1. Space default noise suppression is Standard (libwebrtc NS only). Medium. Effort small.**
- Problem: a member who never opens the picker gets only libwebrtc NS at its fixed kHigh, so keyboard, fan and room noise reach friends.
- Evidence: live GET /version returns strong_noise_suppression:false (VERIFIED-RUN).
  noise_suppression.dart:32-35 and 75-77 default to spaceDefault.
  Migration 0109_strong_noise_suppression.sql:6 is DEFAULT 0.
  Strong needs the native gate, so this is Linux and Windows only (input_gate.dart:20-22).
- Change: the owner flips the Space flag to Strong in admin settings (no release, reread each minute, instantly reversible).
  - Do not make Strongest the default (deepfilternet-evaluation.md:93, and the server flag is one boolean).
  - The "describe what Space default resolves to" suggestion is already shipped (noise_suppression_section.dart:28-33).
    Only the dock mic menu still says a bare "Space default" (section 6, item 19).
- Prove: run the desktop harness (E2E_ONLY="voice desktop") Standard vs Strong on real voices, not the piper -68 dB fan figure (voice-corpus-results.md shows -2 to -13 dB for most real voices).
  Watch the "Strong inactive" note rate and onset clipping.
- Lens doubts: impact and fix lenses call it a deliberate documented default, not a defect.
  The 2026-10-27 decision (mic-handling.md:414-418) already keeps libwebrtc NS on under Strong.
  Onset clipping under Strong plus loss was flagged for re-measure at n above 10 (voice-quality-harness-v2.md:224).

**A2. A silent dead mic is undetected under Strong on Linux and Windows. Low (was medium). Effort small.**
- Problem: the loudness watchdog is paused whenever Strong reads active, and nothing replaces it.
- Evidence: voice_session_mic_recovery.dart:142 returns _micWatchdog.pause() on strongActive.
  The sender-stats poll only starts when !_gate.supported (line 203-207).
  In the fork, NoiseSuppressor::active_ is set only inside ProcessPlanar (flutter_noise_suppressor.cc:215), so it stays true when frames stop.
  VERIFIED-SRC for the code, SUSPECTED for how often a capture stalls without a track-ended or device-change event.
- Change: add a separate 1 to 2 s timer that checks media-source totalSamplesDuration (not packetsSent, which also stalls during resume) is advancing while the mic is wanted, unmuted, open and the room is connected.
  - Route it through the existing SilentMicWatchdog budget and the MicStatus.reconnecting then unavailable path, with a grace after each restart.
  - A native frames-processed counter is optional and costs a fork bump.
  - The same signal should gate _onGateSilent, whose sender audioLevel check may stay stale when frames stop.
- Prove: Linux, Strong on, pactl suspend-source on the default input.
  Time to MicStatus change and to friends hearing audio.
  Unit test with a frozen counter.
- Lens doubts: impact lens says the named real-world faults (unplug, Bluetooth drop) already raise device-change events, so low.

**A3. Dynamics and gate defaults assume levelled speech that does not exist. Medium. Effort small, then maybe medium.**
- Problem: AGC1 is a fixed lift of about +12 dB with no levelling, but comments and thresholds assume levelled speech.
- Evidence: mic-handling.md P5 (2026-10-28) shows the sent level follows input 1 to 1 over 24 dB (-29.5 / -53.4 dBFS for -26 / -50 in; AGC off -41.4 / -65.4).
  - input_gate.dart:15-16, flutter_voice_dynamics.cc:11-13 and voice-input-gate.md:44 describe AGC as levelling to about -18 to -20 dBFS.
  - Chain order is scrub, NS, gate, dynamics (flutter_capture_chain.cc:44-50), and dynamics only reduces gain.
  - audio_gain.dart:26-30 caps the listener fix at +6 dB with hard clip.
  - This was a documented open item (mic-handling.md:208-209).
- Change, step 1: correct the three comments and state that turning AGC off moves levels about 12 dB down, which changes what -50 dBFS means.
- Change, step 2: before building anything, measure level spread across real friends' mics on Linux and Windows.
  Only if the spread is large, prototype a slow leveler (target about -20 dBFS RMS, up to about +12 dB, 500 ms or slower) or a fixed pre-gain option.
- Caveats from the fix lens:
  - A leveler keyed on speech probability is dead on Standard (no probability, the gate gets -1, flutter_input_gate.cc:80).
  - It needs its own flag, not the "Even out loud sounds" toggle.
  - It is desktop only; iPhone and web are unaffected.
  - Up to +18 dB would lift residual noise.
- Prove: repeat the P5 rig with real speech at three gains.
  Sent level should be within about 4 dB, the noise floor in gaps unchanged, and ViSQOL and onset clipping not worse.
- Lens doubts: impact lens rates it low, because P5 is one looped synthetic clip, no field report exists, and the compressor catching only shouts is intended.

**A4. No echo telemetry. Medium. Effort small.**
- Problem: echoReturnLoss and echoReturnLossEnhancement are never read, so echo on speakers is unobservable in the app and the harness (the harness runs with AEC off).
- Evidence: parseAudioSend reads only audioLevel, totalAudioEnergy, totalSamplesDuration (audio_stats.dart:145-153).
  The only mentions are mic-handling.md:140 and :222 (proposed, never built).
- Change: log the raw media-source entry once per platform to learn whether libwebrtc reports the fields (they may be absent when AEC is off or on iPhone voice processing).
  - If present, add them and the receive-side counters (packetsDiscarded, accel/decel, silentConcealed) to the 60 s [voice-health] line and the call summary.
  - Put aggregates in the summary, and per-peer values in the minute line only when non-zero.
  - Share-audio sampling needs its own map key (the per-person map is keyed by identity) and a slower cadence.
  - Do not ship the "ERLE below 6 dB, use headphones" hint.
    ERLE is near 0 with headphones and its range is roughly capped near 6 dB, so the thresholds are wrong.
- Prove: Linux speakers with a second client playing speech, AEC on vs off, then a headset as control.
- Lens doubts: impact lens rates the app gap low (observability only).
  pactl stream moves do not break the AEC3 reference; it is libwebrtc's in-process playout.

**A5. iPhone CallKit and audio session ownership is untested on a device. Medium, device test first.**
- Problem: LiveKit runs AudioSessionManagementMode.automatic while the app also reports calls to CallKit and deliberately omits didActivate/didDeactivate.
- Evidence: VoiceCallReporter.swift:150-160.
  There is no AudioManager, setAudioSessionManagementMode or setEngineAvailability use in client/.
  livekit_client 2.13.1 audio_manager.dart:82 defaults to automatic and activates the session itself.
  OPEN-QUESTIONS.md:21 lists it.
- Change: no code change yet.
  Run the device matrix on a physical iPhone: join, cellular call mid-call, Siri, AirPods toggle, 2 minute lock.
  Log AudioManager.audioEngineStateStream and sender audioLevel.
- Only if audio does not return within about 3 s, try as one change: setAudioSessionManagementMode(externalCallSystem), setEngineAvailability(none) before connect, then available from didActivate and none from didDeactivate.
- Risks of acting blind:
  - A refused CXStartCallAction (Do Not Disturb, other call) means didActivate never fires and the call would join with mic and playout gated off forever.
  - The inbound-answer path uses VoipCallHandler's second provider, which also lacks didActivate.
  - Mic recovery and gate watchers would read a gated engine as a dead mic.
- Lens doubts: impact lens says WebRTC's ADM probably restarts after interruptions and many apps run automatic beside CallKit.
  Route changes are not unobserved: the fork posts onDeviceChange on AVAudioSessionRouteChange and Dart follows it.

**A6. Windows communications audio category may double-process voice. Medium SUSPECTED, measure first.**
- Problem: libwebrtc tags Windows capture and render AudioCategory_Communications (core_audio_utility_win.cc:907 in the prebuilt m150), which can route capture through OEM vendor AEC/NS/AGC.
- Evidence: mic-handling.md:101-105, 167-168.
  The fork's default_audio_endpoint.cc:32 only picks the endpoint role, not the category.
  The ducking opt-out exists in code (audio_ducking_opt_out.cc), but its verification is still an unchecked item (flutter-webrtc-fork-rebase.md:147).
- Change: do not patch or rebuild libwebrtc.
  Log the active capture endpoint's effects, add a Voice help line about Windows Audio Enhancements, and run one A/B on a real OEM laptop plus the ducking check on a Windows PC.
- Prove: sweep or speech clip through the real mic path, spectrum and ViSQOL with enhancements on and off.
- Lens doubts: impact lens refuted it as speculative (Chrome, Teams and Zoom use the same category, and the win11 VM has no OEM driver so it cannot show the effect).
  Fix lens: no category patch is available without a libwebrtc rebuild.

**A7. Linux speaker choice is only re-applied on mic events. Low (was medium). Effort small.**
- Problem: a Pulse/PipeWire speaker pick is applied by moving this process's sink-inputs with pactl, and only on mic enable, mic restart, device-change and one 3 s retry.
- Evidence: voice_session_audio_devices.dart:78-92, voice_session_tracks.dart:139, voice_session.dart:140, voice_session_mic_recovery.dart:275-276.
  pulse_audio_parse.dart:65-68 ignores new sink-input events.
  A muted join with no push to talk never reaches it.
  It is SUSPECTED that libwebrtc recreates the playout stream when the room empties.
- Change: add "new" sink-input to the pactl subscribe filter and run applyServerRouting when one of ours appears.
  Do not use RoomReconnectedEvent (it fires on resume too, before new streams exist) or _watchFirstRemoteAudio (bounded to the join).
- Prove: PipeWire box, default sink A, choose B, join alone, second client joins later.
  Check which sink the playback stream is on at 1 s and 10 s.
- Lens doubts: impact lens refuted it after a VERIFIED-RUN probe on this box.
  Stream-restore re-applies a previous pactl move to a new stream with the same client name, so only a first-run edge remains.

**A8. Burst loss is still audible in the worst case. Low (documented limit).**
- Problem: the gemodel profile (about 6% loss in runs of about 10 packets) still gives ViSQOL 3.98 on one side, with dropouts, level bursts and one static.
- Evidence: results.json for quality-burst.
  voice-bursts.md:37 and :98 ("RED does not fix long loss runs").
  The profile is a worst case: 200 ms outages that depth-1 RED and LBRR cannot cover.
- Change: none now.
  - The audio-network-adaptor route is wrong (the loss is on the SFU downlink, so the sender never sees it).
  - The receive limiter was already decided against (voice-bursts.md:58-63).
  - Only a second RED depth would fit these runs, at a bandwidth cost.
    Revisit only if the owner hears bursts.
- Prove: three or more netem seeds, one profile per invocation until M1 is fixed.
- Lens doubts: impact and fix lenses rated it low, and the measurement is web/Chrome only.

**A9. Per-person volume above 100% hard-clips natively. Low. Effort medium.**
- Evidence: kMaxParticipantVolume is 2.0 and linear above 1.0 (audio_gain.dart:33-36, 49-54, line numbers corrected).
  Web adds a soft limiter (web_gain_web.dart:76-91, soft_limit.dart:26), native does not.
- Change: add an absolute-ceiling soft limiter to the fork's render path, keyed on gain above 1.0 like web.
  Capping native at 1.5 would need the same cap on web, or a saved slider value stops meaning the same gain everywhere.
  voice-bursts.md:62 describes a relative limiter, not this one.
- Prove: 200% gain on a -3 dBFS clip, count full-scale samples with and without the limiter.
- Lens doubts: the libwebrtc saturation itself is SUSPECTED.

**A10. iPhone has no speaker/earpiece control. Low. Effort small.**
- Evidence: there is no setSpeakerOutputPreferred or route picker anywhere in client/.
  livekit_client defaults preferSpeakerOutput to true (mode videoChat).
  The SDK already honours a connected headset; only the earpiece choice is missing.
  Input and output pickers are off on iOS (audio_device_switching.dart:66-85).
- Change: add a speaker/earpiece toggle calling AudioManager.setSpeakerOutputPreferred, and optionally an AVRoutePickerView.
  The echo benefit is SUSPECTED until tested on a device.

**A11. Idle and closed-gate bandwidth with DTX off is unmeasured. Low. Effort small.**
- Evidence: voice-input-gate.md:18 quotes 8 to 112 B/s for a closed gate "with Opus DTX", and DTX has been off since voice-bursts.
  voice-bursts.md:14 says an idle open mic was not measured.
- Change: run a 60 s outbound-rtp bytesSent probe for closed gate, room noise and speech.
  - Judge the delta against DTX on, because RTP/SRTP overhead alone is 16 to 20 kbps at 50 packets/s.
  - Update voice-input-gate.md:18.
  - Only if the delta is large, test DTX on for gated silence and re-run the gliding-tone burst test.
- Lens doubts: the "48 to 80 kbps per silent mic" framing was refuted (VBR silence is a few bytes).

**A12. Stale "livekit_client 2.10.0" comments. Low. Effort small.**
- Evidence: audio_gain.dart:4, audio_device_switching.dart:69, voice_settings_screen.dart:57, voice_roster_snapshot.dart:94, voice_auto_rejoin.dart:6, voice_auto_rejoin_test.dart:6, mic-handling.md:20, 58, 267, 498.
  Each underlying claim re-verified true on 2.13.1 (no per-participant volume API, mobile input picker no-op, 44 s retry ladder identical).
  Leave desktop_dependency_floor_test.dart as historical.
- Change: reword to 2.13.1.
  The harness tables did not move because of an SDK bump; the RED handling explains them.

### 3.2 Screen share

**S1. Desktop capture ignores the requested size; layer sizes, bitrate budget and the admin ceiling may not match real frames. Medium SUSPECTED (code path VERIFIED-SRC). Effort medium.**
- Problem: GetDisplayMedia reads only deviceId, mandatory.frameRate and cursor (flutter_screen_capture.cc:510-545).
  livekit_client reads the real size from getSettings() only on web and mobile (local.dart:329-343).
  - Declared dimensions therefore come from currentOptions, and fitScreenShare only clamps downward (screen_share.dart:126-144).
  - A 4K screen on the default 1080p declares 1920x1080 and q 960x540, while frames may be 3840x2160 with scaleResolutionDownBy 1.0 on the top layer, at a 5 Mbps budget.
  - An ultrawide gets the wrong declared aspect.
  - The admin ceiling bounds declared dimensions and bitrate, not pixels.
  - No desktop run exists (screen-share-quality-2026-10-18.md:97 "Not exercised").
- Change: first measure (below).
  If confirmed:
  - (1) make fitScreenShare use the real source aspect (rounded even);
  - (2) after publish call setParameters with scaleResolutionDownBy computed from the height ratio, with q at twice that.
    Do not use the max-edge ratio, which breaks ultrawide: 3440x1440 at the 1080 tier would come out 1920x804.
    The fork already applies the field (flutter_peerconnection.cc:820-822).
  - Layer presets cannot cap the top layer because computeSimulcastPresets always appends "original".
  - Better still, scale at the native capturer in the fork, which also bounds sender CPU.
  - Keep the prod ceiling at 1080 until verified.
- Prove: share at 1080p30 from a 1440p or 4K display on this box (nested kwin --virtual with an isolated XDG_CONFIG_HOME so the owner's output config is not written; set the virtual output to 4K) and on a Windows PC.
  Read outbound-rtp frameWidth/frameHeight per rid and localShareCapturedSize.
  Expected after the fix: 1920x1080 at 5 Mbps.
- Lens doubts: impact lens trimmed severity (dynacast means rid h only encodes when wanted, and balanced degradation lets libwebrtc shrink an overloaded encode).
  The libwebrtc desktop source scaling is unread, so the effect is unproven.

**S2. First-frame measurement timeout skips the ceiling clamp. Low. Effort small.**
- Evidence: screen_share_publish.dart:79 returns the chosen tier on null before fitScreenShare.
  The timeout is 3 s (screen_share_source_size.dart:23).
  On Wayland the first PipeWire frame may arrive late (SUSPECTED).
- Change: on null, still run fitScreenShare with the chosen size and maxHeight so tier, bitrate and fps are clamped.
  A late re-fit needs a new hook, because localShareCapturedSize is only set when a size was measured.
  Log the elapsed time on Wayland first.

**S3. Data saver for shares requests the same layer as Balanced. Medium. Effort small.**
- Problem: shares publish exactly two layers, rid q (LOW) and rid h (MEDIUM, the full size), with no HIGH.
  layerFor(screenShare: true) returns HIGH for max/auto/balanced and MEDIUM for dataSaver (video_quality.dart:36-42), and the server clamps both to h.
- Evidence: utils.dart:353-370, 597-617.
  The prod SFU log declares LOW 960x540 2 Mbps and MEDIUM 1920x1080 8 Mbps for the 1080p60 tier (VERIFIED-RUN).
  Comments at video_quality.dart:20-24, 34-36 and video-handling.md:129 say Data saver steps shares down.
  A phone viewer's tile (about 390 pt times 3) also exceeds 960 px, so an iPhone on cellular likely pulls 5 to 8 Mbps (inferred).
- Change, owner decision: either dataSaver maps to LOW for shares when the tile is not enlarged, or keep behaviour and fix the comments and copy.
  - The q layer is 960x540, so the old "unreadable" rationale is stale.
  - Enlarged tiles keep the HIGH override.
  - Do not add a third simulcast layer (extra sender encode).
- Prove: a Data saver viewer watching a 1080p30 share, reading inbound frameWidth and bitrate.
  Expect 1920x1080 at about 5 Mbps today.

**S4. Share degradation is balanced in code and maintainResolution in docs. Medium (docs fix certain). Effort small.**
- Evidence: video_publish_options.dart:18, 35 versus docs/video-quality.md:43-49 and video-handling.md:101-127.
  The change came with #2270 on purpose ("lowers quality quietly instead of the banner").
  The SDK default for screen share is maintainResolution (options.dart:363-370).
- Change: fix the docs to the real behaviour now.
  Whether text shares should use maintainResolution and 60 fps shares maintainFramerate is a heuristic.
  Confirm it with the share matrix under CPU or uplink caps, and with the owner, before changing.
  No content hint setter exists in the fork.
- Prove: E2E_SHARE_MATRIX rows with cores or cap_mbps limits, comparing viewer frameWidth and fps per preference.

**S5. Shared audio is mono on the wire. Medium (low by the impact lens). Effort large.**
- Problem: Windows loopback is mono by design (application_loopback_capturer.cc:180, 502, 558), nothing sets TF_STEREO in livekit_client 2.13.1 (local.dart:196-200), and no SDP stereo is negotiated.
  voice-bursts.md:127 already records it.
- Change: option (b) only.
  - Make the Windows capturer output 2 channels.
  - Add TF_STEREO to audioFeatures.
    livekit_client is hosted at 2.13.1 and only flutter_webrtc is overridden, so this needs a patch, a fork or a newer release (check upstream first).
  - Publish with presetMusicHighQualityStereo (128 kbps).
  - LiveKit v1.10.1 adds stereo=1 to the publisher answer when the track carries TF_STEREO (participant_sdp.go:320-390 per the fix verifier), so no client SDP munge is needed.
  - Do not drop to 64 kbps: offline SNR was 20.4 dB at 48 kbps and 26.3 dB at 96 kbps.
  - Linux already captures stereo (pulse_loopback_capturer.cc:33-39) and should follow with no capturer change.
  - Receiver-side stereo playout must be checked per platform.
- Prove: left-only then right-only tone share.
  Check receiver inbound-rtp channels, the negotiated fmtp, and that the right channel is silent on the left-only tone.
- Lens doubts: it affects watch-party and game imaging only, so low by the impact lens.

**S6. Share-audio isolation failure on Linux is ignored. Low. Effort small.**
- Evidence: screen_share_control.dart:126 drops begin()'s bool.
  On false the fork captures the default sink monitor (pulse_loopback_capturer.cc:214-217), which contains the call's own playout, so viewers hear the call echoed.
  supported is just Platform.isLinux (share_audio_graph_io.dart:33).
  The rpm spec requires libpipewire but not pipewire-utils.
- Change: use begin()'s result.
  On false, publish the share without audio and show a persistent one-line AppLog-backed note ("Share audio is off: PipeWire tools not found"), no snackbar (check-error-surface gate).
  Add pipewire-utils to the rpm Requires or document it.
  Do not lower followEvery: it does not affect the echo and costs pw-dump spawns.
- Lens doubts: reach is narrow (Fedora KDE and Ubuntu ship pw-cli).
  Flatpak runtime content is unchecked.

**S7. The sharer renders their own screen back at full tile size. Low. Effort small.**
- Evidence: share_stage_grid.dart:43-66 passes screenShareViewFor for the local sharer too.
  The opt-out already exists ("Hide stream" in the menu, which removes it from activeShares).
- Change: make the local identity stopped by default, or show a "You are sharing your screen" tile.
  Measure encoder CPU and fps with the local tile visible and hidden first.
  The fork converts frames per painted frame at drawn size, so the cost is bounded by refresh rate.

**S8. Start-bitrate hint for shares is uncapped. Low. Effort medium.**
- Evidence: computeTrackStartBitrate exempts screen shares from the 1 Mbps cap (transport.dart:125-131).
  The hint is 0.9 times the layer sum (5.6 Mbps at 1080p30, 9 Mbps at 1080p60), written once per peer connection, so it only applies when the share is the first video published.
  No public lever exists; it needs a livekit_client patch.
- Change: measure first with tc netem/tbf at 8 Mbps on a Linux sender (outbound targetBitrate, packetsLost, RTT in the first 10 s).
  Do not change maxBitrate.

**S9. iOS broadcast extension JPEG-encodes every frame at full device resolution, quality 1.0. Medium SUSPECTED, device-only. Effort medium.**
- Evidence: SampleUploader.swift:96-134 has no scale step.
  The app side allocates a BGRA buffer of the header size (FlutterSocketConnectionFrameReader.m), and the fork ignores constraints for the broadcast capturer.
  - So the 720x1280 request in screen_share_control.dart:346-347 never shrinks what the 50 MB extension handles.
  - The comment at lines 325-345 claiming it does is wrong.
  - LiveKit's own example has a scaleFactor hook that this copy dropped.
- Change: hold until a TestFlight measurement shows low fps, extension kills or heat (viewer inbound fps and frameWidth over 60 s, extension memory in Instruments).
  Then:
  - downscale to a 720 short edge before encoding with a Lanczos transform, never upscale;
  - keep the source CIImage colour space (a nil colour space drops every frame);
  - use JPEG quality 0.7 to 0.8;
  - set Buffer-Width/Height to the scaled size or the receiver crops;
  - keep the app-side request.

**S10. Share liveness recovery is Windows-only. Low, measure first.**
- Evidence: screen_share_watch.dart:40-44 returns unless Windows.
  Linux reacts only to desktopCapturer.onCaptureError.
  Whether a stalled portal stream raises that error is unknown.
- Change: reproduce on KDE Wayland first.
  Do not reuse the Windows frame-progress test on Linux, because a static screen legitimately emits no frames (screen_share_liveness.dart class doc).
  Any recovery must end the share and tell the sharer, not auto-restart, because a restart re-prompts the portal (voice_screen_share.dart:51).
- Lens doubts: the resilience finder's twin finding was refuted for the same reason (unverified premise, and the fix would not work as specified).

**S11. After an auto-rejoin the screen share is silently gone. Low SUSPECTED.**
- Evidence: _onDisconnected stops the broadcast and disposes share control (voice_session_tracks.dart:63-75).
  Rejoin carries only the channel id (voice_rejoin.dart:60-90).
  The empty-roster emit also appears to clear cameraEnabled, so camera intent is probably not restored either (unrun).
- Change: record share intent before the empty emit.
  After rejoin, restart from lastShareSourceId on Windows only, and show a persistent notice elsewhere ("Your screen share ended when the call dropped - share again").

**S12. Docs describe code that no longer exists. Low. Effort small.**
- Evidence: docs/video-quality.md:43-49 (maintainResolution), screen-share-quality-2026-10-18.md:23, 57, 94, 105, 112 (sharer banner, windows not shareable).
  The banner was removed on purpose in #2270 (commit 1bae4b11d: "share-limit monitor is gone"), and window sharing exists on Windows and macOS (desktop_sources.dart:109-132).
- Change: mark the banner as removed on purpose so nobody reintroduces it, update the degradation text, and say windows are not shareable only on Linux.

### 3.3 Camera

**C1. Changing camera quality mid-call never applies the new resolution or encodings. Medium (VERIFIED-SRC, all three lenses). Effort medium.**
- Problem: restartCamera() does off then on, but a camera publication is muted, never unpublished, so unmute reopens with the original options.
- Evidence: the chain is
  - voice_video_controls.dart:101-125,
  - then voice_session_tracks.dart:163-177,
  - then livekit_client local.dart:831-848 (cameraCaptureOptions is read only for stopCameraCaptureOnMute),
  - then track/local/local.dart:208-213 (restartTrack() with no argument),
  - then :306-316 (`currentOptions = options ?? currentOptions`).
  - Simulcast encodings are fixed at first publish (local.dart:331-343).
  - The comment at voice_session_tracks.dart:175 ("Off means the next enable republishes fresh") is wrong.
  - Only fakes cover it (live_quality_restart_test.dart).
  - Changing the setting while the camera is off, after one publish in that call, hits the same path.
- Change: when the requested CameraQuality differs from the one the live track was published at, call removePublishedTrack(pub.sid) then setCameraEnabled(true, cameraCaptureOptions: new).
  - Store the published quality next to _cameraQuality.
  - A plain toggle keeps the cheap mute path.
  - restartTrack(newOptions) alone fixes capture size but not encodings.
  - Facing resets to front on republish, as the off path already does.
  - Add a test that drives a real LocalVideoTrack's currentOptions.
    Fix the comment.
- Prove: A at 720p switches to 360p.
  Before the fix, outbound-rtp still shows the 720p layers.
  After, it shows 640x360 with a 320x180 low layer and 450 kbps top.
- Lens doubts: impact lens rates it medium (a workaround is to leave and rejoin).
  The 3.8 s reopen is a 4K UVC worst case.

**C2. Desktop camera layer sizes use the requested size, not the webcam's delivered mode. Low (was medium SUSPECTED). Effort small to medium.**
- Evidence: the fork passes width/height/fps to Create() and reports those same requested values as settings (flutter_media_stream.cc:411-417, 455-459).
  livekit_client refines only on web and mobile (local.dart:333).
  On a 720p-only webcam at CameraQuality.high the SFU is told 1920x1080 / 640x360 / 320x180 while frames are 1280x720.
- Change: make the fork report the real negotiated capture mode so the SDK's refinement could apply.
  Do not build a custom desktop publish path (setCameraEnabled handles existing publications, mute, stop and publish options).
  The default is 720p, so exposure is mostly 1080p on 720p cameras and 4:3 webcams.
- Prove: 720p-only webcam at the 1080p setting, outbound frameWidth per rid versus the SFU track layers.
- Lens doubts: impact lens refuted it at medium (the top layer is the camera's native frame either way; only the lowest layer is smaller than declared).

**C3. Joining with the camera preset on blocks "connected" on a sequential camera open. Low. Effort small.**
- Evidence: voice_session_join.dart:57-69 awaits mic, then camera, then _primeMutedMic, before _setState(connected).
  Mic watchers, health watch, input gate and the heartbeat all start from connected (voice_session_tracks.dart:221-235, voice_session_sync.dart:89-93).
  Neither open has a timeout.
  A 4K UVC took 3.8 s (video-handling.md:60).
  Roster presence comes from the participant_joined webhook at connect, so presence is not delayed, only the heartbeat-driven activity change.
- Change: mark connected after the mic step and open the camera in the background with a roughly 10 s timeout.
  - Set cameraPending around the deferred open (the join path does not set it, so a user toggle would race).
  - Guard by room identity and generation.
  - Surface a join-time camera failure (today it only sets _lastError).
  - Do not add a hard mic timeout without a guard: a permission prompt can take any time, and a late open would double-publish via _retryMicAfterJoin.
  - _primeMutedMic can move after connect too (setKeepMicReady already does).
- Lens doubts: the resilience finder rated this medium and the camera finder low.
  Typical webcams open fast.

**C4. A camera picked earlier that vanishes silently becomes device 0. Low. Effort small.**
- Evidence: flutter_media_stream.cc:411-431 falls through to device 0 and reports its id.
  The id is session-scoped (room default via setVideoInputDevice), not persisted.
- Change: add a Dart-side check against Hardware.videoInputs() before enabling, and report "chosen camera not available".
  A native error alone surfaces as TrackCreateException and is classified cameraUnavailable (camera_failure.dart:68-72), which would not say it.

**C5. Camera tile is blank until the first decoded frame. Low. Effort small.**
- Evidence: camera_view.dart:150-156 uses SizedBox.expand() as the FirstFrameReveal placeholder.
  call_participant_tiles.dart:181-185 drops the avatar as soon as isCameraOn, which is true for a published but unsubscribed or culled camera.
- Change: keep the avatar mounted until a decoded frame exists.
  CameraView needs to expose a has-frame signal, because it returns SizedBox.shrink() when no track is attached.

**C6. Phone camera policy and codec. Low, device test first.**
- Evidence: cameraPublishOptions sets only degradationPreference, so phones software-encode VP8 simulcast (video-handling.md P7, P10 open).
  The Call stats screen already shows encoderImplementation, powerEfficientEncoder and qualityLimitationReason (call_stats.dart:235-239, call_stats_lines.dart:29, 65), so no new instrument is needed. 720p is already the default (voice_settings_state.dart:24).
  Dynacast means unwatched layers are not encoded.
- Change: run a 15 minute iPhone call at 720p and 1080p, and read the existing screen plus thermalState.
  Only on cpu limitation or a thermal step-down:
  - cap 1080p on phones;
  - trial H.264 behind a setting with a vp8 backup;
  - add the thermal step-down (P7).
- Lens doubts: impact lens refuted it at medium.

**C7. "Max" watching quality is clamped to 3x pixel density. Low. Effort small.**
- Evidence: AdaptiveStreamPixelDensity.resolve caps at 3.0 (livekit_client other.dart:347, 367-371), so a 144x90 tile under Max requests 432x270 and gets the 360p layer.
  The comment at video_quality.dart:62-64 and the enum doc promise the top layer.
  Output is still pixel-sharp.
- Change: fix the comment and add a test that resolves the density through resolve(devicePixelRatio).

**C8. Camera start-bitrate seeds are unrecorded. Low.**
- Evidence: the camera start hint is min(0.9 x layer sum, cap), 1000 kbps at setup time up to 1.5 s, ramping to 300 kbps at 3.5 s (transport.dart:47-61, 111-131), one-shot per connection.
  A share after a camera gets no hint at all.
- Change: only record "connection setup took N ms" and "Applying x-google-start-bitrate" from the livekit logger into diagnostics.
  Drop the share pre-warm and publish-order ideas unless a measurement shows a slow ramp.
  Do not move signaling off Cloudflare on this evidence.

### 3.4 Network and SFU

**N1. The ceiling is the home WAN uplink and it has never been measured. Medium. Effort small.**
- Evidence: docs/sizing.md:195-232 says CPU is not the limit, and :275-276 says sustained video is not covered ("a deployment's own uplink is what decides").
  No uplink figure exists anywhere in docs.
  - Prod shares use an 8 Mbps top layer plus a 2 Mbps q layer.
  - 9 viewers all on the top layer is about 72 Mbps before audio (arithmetic, a worst case).
  - Audio adds about 10 x 9 x 80 kbps = 7 Mbps when everyone's mic is open.
  - The "62 Mbps lower bound" from the Cloudflare HTTP throughput is not valid, because media goes direct over UDP.
- Change: an owner-run upstream test from 10.0.0.100 when the room is empty, recorded in docs/sizing.md with the rule of thumb that viewers x share Mbps stays under about 70% of uplink.
  - Then one fan-out test: one 1080p60 publisher, 5 and 9 external subscribers, 10 minutes.
    Read aggregate egress, subscriber fps, publisher limitation reason and container memory.
  - LAN viewers use the hairpin and cost no WAN uplink.
  - Do not touch DTX.
  - congestion_control is already on by default, so there is nothing to set.
- Lens doubts: impact lens says the docs already name uplink as the video constraint and the scenario is a worst case.
  Raise to high only if the measured uplink is under about 100 Mbps and 8-plus person watch parties are expected.

**N2. LiveKit DeleteRoom returns 401, so deleting a channel does not end a live call. Low. Effort small.**
- Evidence: the prod log shows two DeleteRoom 401 "permissions denied" at 2026-11-02T00:52:43Z and 00:53:13Z (VERIFIED-RUN).
  - room_admin.rs:117-131 mints roomAdmin only.
  - token.rs:21-37 VideoGrant has no roomCreate, which LiveKit requires for DeleteRoom.
  - Callers discard the error (room_cleanup.rs:38 `let _ =`, channels.rs:410-419 warn).
- Change: add roomCreate (skip when false) to VideoGrant and set it only on a dedicated 30 s token for DeleteRoom, never on the shared admin token or join tokens.
  - Test that join tokens never carry it.
  - Log delete_room failures at warn.
- Prove: delete a test channel with one participant connected.
  Expect a 200 and the client getting RoomDisconnectedEvent.
  Also test rejoin with a held token (LiveKit auto-creates rooms, so the rejoin half may not close).
- Lens doubts: the empty-room sweep path is harmless because LiveKit closes empty rooms in 20 s.
  It matters only when an admin deletes a channel during a live call.

**N3. LiveKit v1.10.1 is behind v1.13.11. Low (maintenance). Effort medium.**
- Evidence: release notes fetched from api.github.com.
  - 1.13.2: request the HIGH layer directly.
  - 1.13.6: NACK worker per DownTrack, and TCP fallback preference.
  - 1.13.8: RED history copy, and VP8 sync-frame switch-up.
  - 1.13.10: gap padding, and NACKs on RTX.
  - 1.13.11: capped retransmissions.
  - 1.11.0: RED to Opus timestamp guard (relevant, since every mic is RED).
  - 1.12.0: TURN refuses private-IP peers and credentials get a 300 s TTL.
  - 1.13.1: TTL-less TURN auth removed.
  - 1.13.10: TCP relays refused and relays limited to media ports.
  - The manifest digest for v1.13.11 is sha256:25cd902de7cacbd5f1f779f6a6ac1eae20ba8f56b0935934ce6b0ab80d1e3d20 (amd64 and arm64).
- Change: see section 5.
  The "large sequence number gap" warnings are most likely a spurious log message fixed in 1.13.2 (#4605), so do not use them as a before/after metric.
- Prove: e2e voice quality and share matrix against both versions with the same netem seeds, a TURN relay-only join, and Windows and iPhone join and resume.
- Lens doubts: impact lens refuted the "medium quality" framing.
  Prod audio is already excellent, so this is hygiene with real hardening, not a proven quality win.

**N4. The TURN/TLS relay path has never carried media. Medium SUSPECTED. Effort small.**
- Evidence: the prod startup log shows the default relay range 30000-40000, portTLS 5349, externalTLS true and no udp_port.
  Only 50000-50200/udp and 7881/tcp are published (VERIFIED-RUN).
  No repo doc or test records a relay-only call, and all 14 recent sessions used udp4 host pairs.
  The TLS handshake itself works (TLSv1.3).
- Change: run a debug build with RTCConfiguration(iceTransportPolicy: relay) against prod (livekit_client honours it via ConnectOptions.rtcConfiguration, engine.dart:655) in a private channel and confirm audio both ways.
  - Only if it fails, publish a small relay block (30000-30100/udp, matching the repo overlay), set turn.relay_range_start/end, and have the owner forward it on the router.
  - Also check which TURN URL LiveKit advertises with external_tls true (SUSPECTED that it may not be 5349).
- Prove: candidateType relay and tcp in the call stats network path.
- Lens doubts: impact lens says relay is rarely needed because TCP 7881 ICE-TCP is published.
  A relay-only client only needs the SFU's 50xxx port, so the unpublished 3xxxx range may not matter.

**N5. Smaller network items.**
- TURN/TLS is only on 5349, so a 443-only network gets no media.
  Low.
  - Optional: a Traefik TCP router on websecure with HostSNI turn.npc-server.top and turn.tls_port 443.
  - LiveKit takes one tls_port, so keeping 5349 as a second route would not be advertised.
  - Untested for the target population.
- LAN clients reach the SFU through router hairpin.
  Low.
  - UDP hairpin is VERIFIED working in prod logs (LAN client 10.0.0.178 selected a udp4 host pair against 73.132.148.72 at 2026-11-01T20:00Z).
  - The only open item is the RTT and loss of that pair.
    Measure currentRoundTripTime on a LAN client before adding a LAN candidate or signaling URL.
- Prod and repo voice config have drifted.
  Low.
  - Prod UDP range is 50000-50200 (repo 50100).
  - Prod has TURN/TLS via Traefik with no TURN/UDP, while the repo overlay enables TURN/UDP 3478 plus relay 30000-30100.
  - The prod .env still defines the unused LIVEKIT_TURN_UDP_PORT=3479.
  - The docs are accurate for the shipped compose, so add a prod topology section to an operator note rather than editing OPERATING.md.
- Estimator defaults are unrecorded.
  Low.
  - Prod sets no congestion_control, packet_buffer_size_* or pli_throttle keys.
  - v1.10.1 defaults: congestion control on, allow_pause false, use_send_side_bwe false (REMB downstream), packet buffer 500 video / 200 audio.
  - Closing video-handling.md:191 and :270 with that answer is the whole task.
  - Writing explicit keys is documentation only.
  - Run a use_send_side_bwe A/B in staging only if a viewer-side symptom is measured first.

### 3.5 Resilience

**R1. LiveKit's own reconnect is invisible. Medium (was high). Effort medium.**
- Problem: during an ICE restart, resume or full reconnect the call still reads connected.
  The only reaction is the video stall watchdog's "Reconnecting video" pills, which describe the wrong cause.
- Evidence:
  - RoomReconnected/Resuming are referenced only in audio_event_scope.dart:17 (re-applies audio routing), and RoomDisconnectedEvent in voice_session_tracks.dart:42.
  - RoomReconnecting, RoomAttemptReconnect and ConnectionQuality are never referenced.
  - VoiceSessionState has no reconnecting value.
  - VoiceReconnectBanner is gated on the app-level voice.rejoining, which starts only after the SDK gives up.
  - The ping readout is cleared only in AudioGlitchWatch.stop() (audio_glitch_watch.dart:90).
  - Retry delays are 0, 0.3, 1.2, 2.7, 4.8, then 7 s x5 (engine.dart:56), about 44 s plus up to 1 s jitter per attempt after the second.
  - Prod example: one signal resume that completed in about 250 ms (roommanager.go:349, 2026-11-02T02:25:56Z), and one PEER_CONNECTION_DISCONNECTED close for a Windows wifi client.
- Change, display and logging only:
  - listen to RoomReconnecting, RoomResuming, RoomAttemptReconnect and RoomReconnected in voice_session_tracks.dart (there is no RoomRestarted class in 2.13.1);
  - expose a separate reconnecting flag, not a new VoiceSessionState, because many gates key on state == connected (voice_flags.dart, call_header_facts.dart:66, voice_call_controls.dart:438, account_host.dart:246), and include it in VoiceFlags equality;
  - show it in the existing banner slot with a debounce of about 2 s so sub-second resumes do not flash, reuse the neutral copy "Reconnecting to the call.", and clear on RoomReconnectedEvent, RoomDisconnectedEvent and teardown;
  - clear the ping readout while it is set;
  - log each transition with the elapsed time, and add transport blip counts and durations to the call summary (voice_health.dart is already 378 lines, so put the counter in a new file);
  - amend decision 0075 (lines 32-37) to say display-only observers are allowed.
- Prove: cut only the media path (iptables DROP on udp 50000-50200 and tcp 7881 while HTTPS stays up) for 5, 20 and 60 s.
  - The existing downlink netem cut does not isolate this case, because the sync socket then drops and the "Offline" cue already appears.
  - A silent drop is detected only after the signal ping timeout (about 15 s by LiveKit default, SUSPECTED), so a "within 2 s" target is not achievable by this route.
  - Report banner time, RoomReconnected time and first remote audio.
- Lens doubts: impact lens notes the common blip is imperceptible and per-tile poor-connection badges probably already fire on a media drop (unmeasured).

**R2. A full SDK restart empties the roster. Low (was medium). Effort small.**
- Evidence: room.dart:599-618 clears remote participants and emits ParticipantDisconnectedEvent for each.
  The roster is rebuilt from room.remoteParticipants (voice_session_tracks.dart:184-215), so isAloneInCall (call_solo.dart:11-12) turns true, the stage shows "you are the only one here", and hold music can start after the 3 s grace (hold music defaults off, voice_settings_state.dart:19).
  canvas_presence_layer.dart:136 and share_watch.dart:136 already work around it.
- Change: hold back the roster emit in the rtc layer while reconnecting is set (not a two-sided gate on hold music and callAloneProvider).
  - Unfreeze by rebuilding from the live room, not by restoring the old snapshot (people who left would reappear).
  - Clear on RoomDisconnectedEvent and in _teardown, and also if RoomReconnectedEvent never comes (it is emitted only after rePublishAllTracks completes).
  - Keep _applyLocalAudioState, _applyVideoInterest and applyReceiveVideoQuality running during the freeze.
  - Fold into R1.

**R3. The stall watchdog blames the sharer and churns subscriptions during a reconnect. Low. Effort small.**
- Evidence: voice_session_stall.dart:62-110, 135-185 never read the connection state.
  The card subtitle is "$name's screen stopped sending frames" (video_health_overlay.dart:117-119).
- Change: gate recovery steps on a non-connected room state (the R1 flag), not on VoiceHealth poor, which takes 5 s to set and 10 s to clear and would delay recovery for real sender stalls.
  Reword the share subtitle to something neutral.
  Shares are already protected on a clean downlink cut by needsTraffic; the churn is mainly cameras and the lossy-but-alive share case.

**R4. serverShutdown and stateMismatch end the call as "removed" or "unknown", and are never retried. Low. Effort small.**
- Evidence: voice_disconnect_reason.dart:17-21, 31; voice_rejoin.dart:53-55.
  Whether a normal container stop sends a leave with SERVER_SHUTDOWN is unconfirmed.
  SIGTERM likely drains, then SIGKILL sends nothing, and the SDK ladder plus connectionLost already covers it.
- Change: map serverShutdown and stateMismatch to connectionLost.
  Leave unknown as an answer.
  Keep participantRemoved, roomDeleted, roomClosed and duplicateIdentity.
  Add a test row for every lk.DisconnectReason value.
  Test with docker stop at the default timeout and with -t 0.

**R5. Linux join depends on a NetworkManager D-Bus query inside livekit_client. Low SUSPECTED.**
- Evidence: signal_client.dart:111-130 awaits Connectivity().checkConnectivity() unguarded.
  connectivity_plus 7.3.1 (nm 0.5.0) connects with a try/finally and no catch.
  The Flatpak has no system-talk-name.
- Change: test with NetworkManager stopped (static IP) and in the Flatpak.
  If it fails, catch around the call (a ConnectivityPlatform override returning other) rather than only adding --system-talk-name, because systemd-networkd and iwd-only hosts fail the same way.

### 3.6 Measurement

**M1. The voice quality scenario records only the first profile. Medium. Effort small.**
- Evidence: scripts/lib/e2e_voice_quality.py:339-340 `pair = pair or _record_profile(...)` short-circuits (the original finding's lines 343-344 are the finally block).
  The default run uses all five profiles (lines 268-273), so it is clean-only too.
  It has been present since ce1716e1e (v115).
- Change: extract the loop into a helper, `_record_all(ca, cb, directory, wanted, record=_record_profile)`, that calls record for every profile and keeps the first non-empty pair.
  - Test it with a stub in scripts/lib/test_e2e_voice_quality.py.
  - After the loop, assert that each wanted profile has its recording artefacts (vqa-rx.wav and vqb-rx.wav), not just a folder, because the folder is created before recording.
  - Check e2e_voice_latency.py:70 for the same pattern.
  - A default run now takes about five times longer.
- Prove: E2E_VQ_PROFILES=clean,loss5-jitter30,burst yields three result folders and three table rows.

**M2. The voice experience scenario cannot do a warm rejoin. Low (was medium). Effort small.**
- Evidence: shard-xp.log:21-22 and 49-51.
  The screenshot e2e-par/shard-0/shots/vqb-missing-Leave-call.png shows the lobby join bar "Rejoin - 1 here".
  The product re-click rejoins by design (voice_channel_tap.dart:57-66) and e2e_voice_rejoin.py covers it, so the harness click is the likely fault.
  timed_join (e2e_xp.py:80-96) uses e2e_js.click on the label "lounge", which e2e_voice.py:83-105 documents can hit the "Manage" kebab once the roster is non-empty (SUSPECTED, not reproduced).
- Change: use the _click_channel_row prefix tap (or click the Rejoin label).
  Make timed_join raise when IN_CALL never appears.
  Run the cut stage independent of the repeat-join loop (E2E_XP_JOINS=1 should still yield speaking-ring lag and the cut).
  Add cuts of 3, 10, 30 and 60 s with three repeats each.
  - A 3 s cut may never reach ICE disconnected (it took about 7.5 s on 2026-10-19).
  - A 60 s cut exceeds the 44 s ladder, so a full rejoin is the expected result.
  - This is the web build in Chrome, so native ICE timings need the R1 logging from real clients.

**M3. The quality harness measures Chrome with processing off. Medium. Effort small, then large.**
- Evidence: e2e_voice_quality_js.py:16-29 forces NS, AEC and AGC off (deliberate: "judge the call alone").
  - Neither the Chrome version nor the libwebrtc milestone is in results.json (provenance() at lines 126-137 records commit, variant and env only).
  - The fork pin is libwebrtc.m150.7871.03 (flutter-webrtc-fork-rebase.md:25, 87; docs/dependencies.md:276), so the "not recorded" line in mic-handling.md:30 is stale.
  - A native Linux sender arm already exists (e2e_voice_desktop.py with the real client, SLIMM_VOICE_HARNESS and a PipeWire virtual mic, judged by a Chrome listener).
- Change: stamp the Chrome version and libwebrtc milestone in every results.json, and label the Chrome arm as the network-impairment control.
  - Then extend the desktop harness with a native receiver arm that records the app's null-sink monitor (desktop_audio.py) into the same ViSQOL, concealment and chirp latency pipeline.
  - Windows and iPhone playout stay unmeasurable by this.
- Lens doubts: impact lens rates it low, and the receive path (NetEq, Opus, RED) is the same libwebrtc code.

**M4. Sender-side video stats are not sampled, and the debug ring floods. Medium (was high). Effort small.**
- Evidence: the sampler already runs for viewers (the stall watchdog and StreamQualityRow listen, call_stats_sampler.dart:62-76) and logs a [call-stats] line per sample unconditionally (voice_session.dart:226-229).
  - A sender who watches no remote video gets nothing, and there is no per-share summary.
  - The debug log is a 200-entry ring (debug_log.dart:93, debug entries evicted first), so about 30 lines a minute per remote track push out the once-a-minute [voice-health] line.
  - docs/video-quality.md:56 is stale on this.
- Change: keep the sampler running while a camera or share is published.
  - Add a per-share summary at stop: seconds per qualityLimitationReason, mean sent fps and bitrate per rid, encoder, freezes, time to first frame.
  - Log remote samples at a slower cadence or outside the ring.
  - Add a short audio section to the stats screen.
  - The "Log to console" toggle only forces sampling; rename or document it.

**M5. Windows and iPhone have no field data. Medium. Effort small.**
- Evidence: prod clientInfo shows 12 Windows sessions from two users, 2 Linux sessions from one, and no iPhone.
  harness-v2.md:242 lists Windows, macOS and real devices as not verified.
  The win11 VM's SLIRP network blocks WebRTC.
  Share-audio loopback on the VM was probed on 2026-10-18 (video-handling.md:329), so "no Windows evidence at all" is too strong, but no end-to-end Windows call has been measured.
- Change: extend the existing Call stats screen and debug-log copy (debug_log_page.dart:22-30) with a one-tap "Copy call diagnostics" in Settings, Troubleshooting.
  - It bundles the [voice-health] summary, [call-stats], selected devices, ICE path, join timings and platform.
  - Ask two Windows friends for one 10 minute call each.
  - Optionally fix the VM network (passt or bridged) for a headless Windows client.
- Owner decision, optional: a server-side quality record.
  - Decision 0008 (space analytics: default off, aggregates only, no names attached to counts) is the precedent.
  - Any such record must be an opt-in Space toggle with anonymous aggregates, gated by MANAGE_SERVER, never per-user rows keyed to a call.
  - It needs an openapi.yaml entry and a client binding (schema_coverage and app_reachability gates).
  - No Prometheus scraper exists and STRATEGY.md:478 rejected bundling one.

**M6. Real screen-share encode has never been read back from native hardware. Medium (was high). Effort medium.**
- Evidence: screen-share-quality-2026-10-18.md:58, 65-67, 97, 117 say H264 and 4K rows need real hardware and the desktop path is unexercised.
  No videoCodec is set (video_publish_options.dart:26-36), so Linux and Windows will almost certainly show libvpx VP8 software encode even on real hardware; only iPhone could use VideoToolbox.
  All 8 recent prod shares used the 1080p60 tier, whose only evidence is the 28 fps synthetic result.
- Change: run the CallStatsSampler on a real Linux share (nested kwin, real PipeWire, a looping 1080p60 video file) and on a Windows PC at 1080p30, 1080p60 and 1440p60.
  - Record per-rid frameWidth, fps, targetBitrate, qualityLimitationReason and encoderImplementation for 60 s.
  - Run against the local e2e stack, never prod, and not while the box is being used for gaming.
  - Add a codec axis (vp8 vs h264) as a measurement only.
  - This is the same run that settles S1.

**M7. Smaller measurement items.**
- Prod log tally (low): a 20-line script over `participant active` (connectionType, os, network, connectTime p50/p95) and `ice reconnected` counts per day.
  Alert on any tcp or relay selection.
  Make JOIN_NETEM=wan70 (already defined at e2e_voice_join_time.py:26) a default or CI row so the 1.5 s join target means something.
  Whether the Windows 1.2 s is RTT-driven is an open question.
- Network impairment arms (medium):
  - uplink loss and rate cap on SFU ingress from the existing netem sidecar (a policer);
  - a relay arm with a turn block added to the e2e LIVEKIT_CONFIG (without use_external_ip, which breaks localhost ICE);
  - an SFU CPU arm using lk load-test publishers with --cpus 2 --memory 512m, plus 2 to 4 real browsers for concealment.
  - The three-browser scenarios that exist (e2e_voice_multishare.py, e2e_canvas_crowd.py) have no netem or audio scoring.
  - Heartbeat starvation under a saturated uplink is SUSPECTED and needs browser-side egress shaping.
- Prod-like SFU config (low): extend the LIVEKIT_CONFIG string in scripts/e2e-stack.sh:94 with the prod audio keys.
  The audio keys affect only active-speaker events, not ViSQOL.
- Nightly voice quality (low): an advisory tripwire.
  - Clean and loss5-jitter30 only, 45 s clips, repeated and median-aggregated.
  - Generous bands (about 0.3 MOS and 30 ms) measured on the runner itself.
  - Chrome and livekit-server versions recorded.
  - A separate job (it needs the slimm-visqol image, piper and the netem sidecar).
  - RED/DTX regressions are already pinned by audio_publish_options_test.dart.
  - Needs a docs/ci.md row and must stay out of release.yml required_checks.
- Native chain CPU (low): add process CPU and worst-frame ms to the [voice-health] line and run once on the weakest friend's Windows laptop with Strongest in a 6-person call (deepfilternet-evaluation.md:122 is one Zen 5 machine).
- Camera arm (low): fake video device.
  - Expected layers: 360p = 2 (h180 plus 640x360), 720p and 1080p = 3.
  - fps at least 25, freezeCount 0, restart gap recorded rather than assumed.
  - Defer real hardware until CAMERA appears in prod logs.

## 4. Proposed new defaults

Everything not listed here should stay as is.
Rows marked "owner" need an owner decision, and rows marked "measure" wait for a number.

| Setting | Current | Proposed | Why |
|---|---|---|---|
| Space strong_noise_suppression (prod) | false (Standard) | true (Strong), owner, after a real-voice check | Fan, keyboard and room noise reach friends today (A1). |
| Mic publish: RED / DTX / bitrate | RED on, DTX off, 48 kbps | no change | ViSQOL 4.39 clean, 4.38 under loss; 32 kbps no better, DTX gives clipped bursts. |
| Mic capture chain, gate -50 dBFS, auto sensitivity off, kMicReleaseGrace 15 s | as is | no change | Documented and measured; fix comments only (A3). |
| Health thresholds 5%/3%, 160/120 ms, 400/300 ms, 5 s/10 s | as is | no change | Replay of recorded stats shows the worst profile does trip the glyph. |
| Screen share default tier | 1080p30 5 Mbps | no change | Matches LiveKit's anchor. |
| Space screen_share_max_height | prod 1080 (server default 2160, space.rs:18) | keep 1080 on prod until S1 is measured | The cap does not bound pixels on desktop today. |
| Screen share degradation | balanced | keep; fix docs now (S4); fps-tier mapping only after the matrix | Recorded owner choice (#2270). |
| Data saver for shares | MEDIUM (= full layer) | LOW when tile not enlarged, owner; else fix copy (S3) | The control currently does nothing for shares. |
| Share audio | mono 96 kbps, RED off, DTX off | stereo 128 kbps (presetMusicHighQualityStereo) with 2-channel Windows capture, owner, needs a livekit_client patch | Watch parties lose imaging (S5). Not 64 kbps. |
| Camera quality change mid-call | off/on, keeps old options | republish when quality differs (C1) | The setting is inert today. |
| Camera on join | awaited before connected | deferred with a 10 s timeout (C3) | A slow open holds the UI at connecting. |
| Camera tile ceiling | 320x200 | grow toward about 640x400 for small camera calls, grid-wide (section 6 item 8) | Tile size, not layer logic, limits what a viewer sees. |
| Share grid columns | from window width | from pane width, min tile about 280 (2 cols) / 320 (3 cols) | 3 shares give about 150 px tiles at a 1000 px window. |
| Reconnect display | none until SDK gives up | separate reconnecting flag, 2 s debounce banner (R1) | Invisible for up to about 44 s. |
| serverShutdown / stateMismatch | removed / unknown (no retry) | connectionLost (retry) (R4) | Hardening. |
| LiveKit image | v1.10.1 | v1.13.11 pinned by digest, after staging (section 5) | Media-path fixes, TURN hardening. |
| Prod UDP range | 50000-50200 | 50000-50100 or document 200 | Drift; 100 ports is ample for 10 people. |
| LIVEKIT_TURN_UDP_PORT (prod .env) | 3479, unused | remove | Stale. |
| packet_buffer_size_video, pli_throttle, use_send_side_bwe, congestion_control | defaults | no change; record the effective values | No viewer-side symptom measured. |
| Heartbeat STALE_AFTER | 40 s | no change | The SFU closes a media-dead participant at about 20 s anyway. |
| Windows audio category | Communications (prebuilt) | no change; measure on an OEM laptop (A6) | A libwebrtc rebuild is not justified by speculation. |
| JOIN_NETEM default in the join-time scenario | clean | wan70 | The 1.5 s target is trivially met on loopback. |

## 5. Prod infra changes

All changes are to the prod compose on 10.0.0.100 and docker-compose.voice.yml.
Nothing here was applied.
The audit only read prod (docker compose config, logs, stats).

```
# 1. LiveKit image (docker-compose.voice.yml:60, prod compose, scripts/e2e-stack.sh:38 LIVEKIT_VERSION)
- image: livekit/livekit-server:v1.10.1@sha256:698a1399...   # existing pin
+ image: livekit/livekit-server:v1.13.11@sha256:25cd902de7cacbd5f1f779f6a6ac1eae20ba8f56b0935934ce6b0ab80d1e3d20
# deploy/README.md:124 and deploy/.env.example:140 mention the tag only in an example, bump cosmetically.
```
- Risk: TURN behaviour changes.
  - v1.12.0 refuses private-IP peers and gives 300 s credentials.
  - v1.13.1 removes TTL-less TURN auth.
  - v1.13.10 refuses TCP relays and limits relays to media ports.
  - Prod relays to a container address behind NAT with use_external_ip, and relay has never been exercised, so a TURN regression would be silent.
  - Check the config keys still parse (rtc.use_external_ip, turn.external_tls, audio.*).
  - The Watchtower label is on, so pin by digest and deploy in a maintenance window.
- Rollback: restore the previous digest line and `docker compose up -d livekit`.
  The config is unchanged, so nothing else moves.
- Staging checks first: a relay-only join (item 3), livekit_client 2.13.1 join and resume from a Windows and an iPhone build, and the e2e quality and share matrix against both versions.

```
# 2. Align the media port range (prod .env)
- LIVEKIT_UDP_PORT_END=50200
+ LIVEKIT_UDP_PORT_END=50100     # or keep 200 and document why
- LIVEKIT_TURN_UDP_PORT=3479     # nothing reads it
```
- Risk: the router forward must match.
  Shrinking is safe, growing is not.
- Rollback: restore the previous values and the router rule.

```
# 3. Only if a relay-only join to prod fails (N4)
+ ports: "30000-30100:30000-30100/udp"
+ turn.relay_range_start: 30000
+ turn.relay_range_end: 30100
```
- Risk: the owner must forward the block on the router, and it adds a published range.
- Rollback: remove the three lines.
  Do this only after the test in N4 shows failure.

```
# 4. Optional TURN on 443 (N5)
+ traefik tcp router on websecure: rule HostSNI(`turn.npc-server.top`), tls terminate, service livekit:443
+ turn.tls_port: 443
```
- Risk: LiveKit advertises one tls_port, so 5349 clients would stop being told about 5349.
  It is untested on a 443-only network.
- Rollback: restore tls_port 5349 and drop the router.

```
# 5. Documentation-only config (no behaviour change)
+ rtc.congestion_control: {enabled: true, allow_pause: false}     # equals the default
# packet_buffer_size_video 1000 and use_send_side_bwe true only after a measured viewer-side symptom.
```
- Risk: allow_pause: true appears in the sample config, so spelling the default out guards against a copy.
- Rollback: remove the keys.

Other notes:
- Server code (not infra) ships through the normal PR path: the roomCreate grant for DeleteRoom (N2).
- Owner-run measurements that touch prod are the upstream speed test with the room empty (N1) and a relay-only debug-build join in a private channel (N4, memory rule: test only in a private channel).
- Container limits (2 CPU, 512 MiB) need no change.

## 6. Lounge UX

The call stage, dock, overlay and fullscreen were read in source.
The existing snapshot and geometry suites already cover the call stage, dock, header and many share states.
They are test/ui_snapshot_call_dock_test.dart, ui_snapshot_call_header_test.dart, features/voice/call_screen_phone_snapshot_test.dart, voice_snapshot_scenarios.dart, call_stage_shares_test.dart, voice_reconnect_layout_test.dart and fullscreen_video_chrome_test.dart.
A finding that those surfaces have no snapshots was refuted, because only the gitignored client/packages/app/build/ui-snapshots from a partial local run had been inspected.
Real PNGs reviewed: voice-idle-desktop-dark.png, voice-idle-phone-light.png, voice-rail-desktop-light.png, notify-voice-voice-phone-portrait.png, notify-voice-voice-desktop.png, notify-voice-voice-desktop-end.png.
Items without a file name are source-only.

1. **Phone dock: mic and share options are long-press only, with no caret and no hint. Medium (was high).**
   - Evidence: voice_call_controls.dart:168-172, 191, 298; call_dock_button.dart:80-83 (manual tooltip).
     Decision 0047 line 174 says the rule "replaces hidden long-press-only routes".
   - On iPhone the mic menu only holds a "Voice settings" link (no device picker or gate, audio_device_switching.dart:73, input_gate.dart:20-22).
     The real hidden feature is share resolution and fps.
   - Fix: a first-call coach mark on the share button, or a 44 dp share-options chip.
   - A permanent chip does not fit the width budget (decision 0047: 293 of 336 at 360), and the compact card was shrunk at the owner's request on 2026-10-02.
   - Amend 0047 and cite the desktop-vs-mobile rule number.
2. **Reconnect state** - see R1 (banner slot, ping, 2 s debounce).
3. **Stage controls live only in a context menu. Medium.**
   - Evidence: screen_share_stage.dart:97-151; share_stage_controls.dart:42-76; stream_quality_row.dart.
     Watching quality has no in-call control (call_quality_options.dart:19-22, docs/video-quality.md:11).
   - Fix: a hover/tap-revealed strip reusing the pop-out's _HoverReveal and _StreamVolume pill (popout_window_view.dart:60-80, 259-290), a live quality chip, full screen, "..." to the menu, and a Watching quality pick written through receiveVideoQuality (global, so label it that way).
   - PointerRevealed shows permanently when no mouse exists, so the strip needs its own touch timer.
   - Buttons must absorb pointers so a double click on them does not enter full screen.
   - Put it in its own widget file and update docs/video-quality.md.
4. **Fullscreen has only a name and a close button. Medium.**
   - Evidence: fullscreen_video_overlay.dart:184-210, 236-272.
   - Fix: add stream volume (reuse the ShareStageMenu streamVolume), mic and deafen, with the strip from item 3 and the same reveal.
     Hold the header while a control is dragged.
   - Camera routes have no stream audio, and local shares have nothing to attenuate.
     Desktop already has mute and deafen hotkeys.
   - Drop one-tap Leave from the first pass (misclick hazard).
5. **"Hide stream" strands a viewer. Medium.**
   - Evidence: share_stage_controls.dart:76-84; share_watch.dart:41.
     The only restore is "Show stream" in the sharer's participant menu (participant_stream_menu.dart:69-78).
     The "opt-back-in chip" in the doc comment (share_stage_controls.dart:2-3) was never built.
   - Fix: when a share is in stopped and still sharing, show a slim "<name> is sharing - Watch" row (a banner above the grid, since there is no stage left).
   - Relabel to "Stop watching" / "Watch stream" like the mini player (call_mini_player.dart:229-232), and give the tile badge a distinct hidden state.
   - Skip sharers in `held`: direct-play stands in for them, and watch() clears held and would disable it.
6. **Share grid picks columns from the window width, not the pane. Medium.**
   - Evidence: share_stage_grid.dart:26-34, 94-98.
     The pane is about 486 px at a 1000 px window with the member pane docked (rail 248, handle 30, pane 236), so 3 shares are about 150 px tiles and 2 shares about 237 px.
   - Fix: compute columns from constraints.maxWidth inside the LayoutBuilder.
     Use a min tile of about 280 for 2 columns and 320 for 3, keep 2x2 for four, and fall back to 1 column with the existing Focus action.
     Do not auto-focus a share.
   - The existing test (call_stage_shares_test.dart:86-93, pumped without rail or member pane) locks in window-width input, so rewrite it and add geometry tests at pane widths about 355, 510, 700 and 1400 with 2, 3 and 4 shares.
7. **A sharer's mute state is not drawn on their tile. Medium.**
   - Evidence: call_participant_tiles.dart:360-365 picks one glyph, so the share icon replaces mic-off and only the colour changes.
     The rail draws separate glyphs (rail_voice_participants.dart:109-114; the cited voice_strip_indicator.dart is controls only).
   - Fix: render a row of badge circles (deafen, mic-off when muted, share), and extend _badgesReachAvatar (:320-339) to count three.
     A camera badge is not needed, because a live feed already replaces the avatar.
8. **Camera tiles are capped at 320x200. Medium (reframed).**
   - Evidence: call_participant_tiles.dart:33-40, 78; call_stage_layout.dart:395-401 (720 column); content_column.dart:18.
     Dynacast means the quality setting is not wasted upload; what is lost is tile size.
     DPR 2 already requests 640x400.
   - Fix: let camera tiles grow toward about 640x400 for small calls, applied grid-wide so tiles do not jump when someone toggles a camera.
     Measure per-tile CPU first (video-handling.md:172).
     Leave the 0.625 aspect alone.
   - Decision 0047 point 10 (docs/decisions/0047-call-dock.md:157) records the 320x200 tile, so cite that, not 0097.
9. **The poor-connection badge is a 12 px glyph whose text is only a tooltip. Medium.**
   - Evidence: call_participant_tiles.dart:301-303, 326-346.
     It violates desktop-vs-mobile.md:55 (never a tooltip as the only carrier, never on touch) and rule 6 (a degraded call is a banner, not an overlay).
     docs/voice-health.md:29 wrongly says the glyph follows rule 6.
     The label already differs for the local tile ("your connection is unstable").
   - Fix: a persistent in-flow banner for our own bad connection, and a tappable glyph with the same text for others (a remote flag cannot say whose fault it is).
     Keep the 5 s/10 s hysteresis.
     Only add an action if it helps audio; "Lower video quality" does not.
10. **No camera options menu and no output device in the call. Medium.**
    - Evidence: voice_call_controls.dart:258-274; mic_options_menu.dart:96-140.
      The camera device switch exists once a camera is on (showCameraDeviceSheet), but camera quality and mirror live in Settings only.
      The v115 change deliberately replaced the speaker button with deafen (ce1716e1e).
    - Fix: a camera menu (device, 360/720/1080, mirror) and an Output section, backed by the same settings notifiers.
    - Gate it like the mic caret (touch and tight use long-press).
      Put it in its own file, because voice_call_controls.dart is 482 lines and pinned at 3 comment runs.
      Share it with dock_solo_controls.dart:105.
    - The Output list is hidden on iOS and web.
      Delete the stale comments at call_dock_button.dart:4 and voice_call_controls.dart:35.
    - The mic menu already deep-links to the Voice pane, so today it is 3 to 4 taps.
11. **Filmstrip with a share: scrollbar and speakers off screen. Medium SUSPECTED.**
    - Evidence: call_stage_layout.dart:341-366.
      The default desktop scrollbar exists (thin, auto-hiding, app_theme.dart:240-253), but there is no persistent overflow cue.
      A plain wheel does not scroll a horizontal list (Shift+wheel does), mouse drag is excluded by default, and the speaking ring is on the tile only.
    - Fix: a Scrollbar with thumbVisibility when it overflows, a ScrollBehavior with mouse and trackpad drag, wheel mapping only for the strip (not inside the multi-share SingleChildScrollView), and a ringed "N more" chip for a hidden speaker.
    - Do not auto-scroll to the speaker (design choice at call_stage_layout.dart:18-20).
12. **Cover fit in a 16:10 tile crops portrait feeds. Low (was medium).**
    - Evidence: camera_view.dart:163.
      A 9:16 iPhone feed shows 35% of its height (assuming the receiver applies rotation, which the fork's renderer does).
      Fullscreen, pop-out and the mini player reuse the same CameraView with cover.
    - Fix: make the fit a CameraView parameter per surface.
      Use contain in fullscreen and pop-out, contain or a taller tile for portrait in the grid, and cover for the canvas bubble.
      Do not change _kCallTileAspect (shared with avatar tiles and goldens).
13. **No cue when talking while muted. Low (was medium).**
    - Evidence: mic_call_button.dart:69-71 gates the level on microphoneEnabled.
      The gate poll is off when muted unless a meter is shown (voice_session_input_gate.dart:114-120), but the level-display path works while muted (voice_session_gate_consumers_test.dart:158).
    - The 15 s kMicReleaseGrace means there is no signal after that, and on Linux the engine drops the source within 0.6 s of mute (mic-handling.md:501-503), so the cue would rarely fire where it matters.
    - Skip unless the owner wants it for the grace window.
      Do not rely on sender audioLevel while muted.
14. **Name labels have no scrim. Low.**
    - Evidence: call_participant_tiles.dart:195; share_stage_grid.dart:158-165.
      It is white text over video.
    - Fix: a translucent pill like MediaLabelChip (media_label.dart:119-147, a pill, not a gradient) or a bottom scrim, in both places.
15. **Blank camera tile before the first frame** - see C5.
16. **Rail click joins live with the saved mic and no pre-join check. Low (was medium).**
    - Evidence: voice_screen.dart:139-145, 156-160; voice_controller.dart:218.
      Making auto-join muted would contradict the owner removing the lobby twice.
    - Fix: a "Mic: <device>" cue beside the existing level bar on first run or when the saved device changed.
      The first-run device step already has a mic test.
17. **iPhone "Voice activity sensitivity" slider only moves speaking rings. Low (was medium).**
    - Evidence: voice_settings_screen.dart:48-82, 115-155.
      It filters every participant's ring on this screen (voice_roster_snapshot.dart:29-37, 99-104), not just ours, and never changes what others hear.
      It has no description.
    - Fix: add "Only changes when speaking rings light on your screen.
      It does not change what others hear." Keep the control so a persisted Strict can still be undone.
    - Snapshot: notify-voice-voice-phone-portrait.png.
      It also shows desktop-only shortcut rows, because isDesktopHost is true in every flutter test, which is a fidelity gap for that pane.
18. **Idle lounge nits. Low.**
    - voice-idle-desktop-dark.png: "Open canvas" is a ghost button that reads as a caption (call_moments_view.dart:119-124).
      The status line "empty - last call yesterday" repeats the header two blocks below (voice_join_bar.dart:136-139).
      Content ends at about 80% of height.
    - voice-idle-phone-light.png: "4 more" starts at x=58 against list x=32, because the ghost sm button carries 12 dp of horizontal padding (call_moments_view.dart:58-63, button.dart:43).
    - Fix locally (a zero-padding text button for the fold link).
      Changing the shared ghost style needs a design-system decision.
19. **Copy. Low.**
    - notify-voice-voice-desktop-end.png: "Share device audio" and "Your camera" have no description (video_quality_sections.dart:92-98).
    - The Watching row has one ("Video and screens from others.") but it does not say what Max/Auto/Balanced/Data saver change.
    - The dock mic menu shows a bare "Space default" (mic_options_menu.dart:27-32).
      Use "Space default (Strong)" as channel_settings_retention_row.dart:103 does.
    - Follow settings-copy rules (short label, one short sentence, no implementation detail).
20. **Call shortcuts for camera, share and leave are not listed or remappable; mute, deafen and Leave share one red outline. Low.**
    - Evidence: shortcut_overrides.dart:19-22; voice_shortcuts_section.dart:53; shortcuts.dart:136-138; call_dock_button.dart:124-125, 150-159.
      Decision 0047 points 2 and 3 contradict each other.
      notify-voice-voice-desktop.png shows only two shortcut rows.
    - Fix: add the three actions to remappableActions with the existing conflict check.
    - Differentiating Leave is an owner design call.
      call_dock_button.dart:124 says "danger is outlined, never filled", so use a heavier outline or a hover-only fill, not a solid resting fill.
      Reconcile 0047.

Also see A10 (iPhone speaker/earpiece) and S7 (self preview).

## 7. Canvas

Nothing crazy found.
Checked and fine:
- Video culling end to end.
  - Presence hysteresis is 200 enter / 600 exit (canvas_presence_visibility.dart:35-45).
  - The interest relay unions every surface (video_interest_relay.dart:87-91).
  - The 3 s dwell and immediate resubscribe are in video_subscription_culler.dart:48, 176-206.
  - Audio is never culled.
- Share audio keeps playing while the canvas is panned (_applyShareAudioBlock only blocks user-blocked shares, voice_session_video.dart:62-77).
- A canvas open on another channel cannot tear down the call's video (canvas_pane_helpers.dart:105-107).
- Per-tile video widgets are cached and sized at real drawn size, so adaptive stream sharpens on zoom.
- Server caps:
  - 20,000 objects default and 100,000 max (store/canvas/canvas_geometry.rs:32,41);
  - 4 KiB props and 8 KiB body (http/canvas/canvas_write.rs:67,70);
  - a 900 KB viewport byte budget (http/canvas.rs:219).
- The ink cache is capped at 24M px (canvas_ink_cache.dart:25-35).
- The commit queue is serial FIFO with stable ids, and sync is seq-ordered with bounded catch-up.
  Only the first 200 lines of canvas_sync.dart were read, so sync correctness is not fully covered.
- Gesture handling, and the voice_canvas suite (564 tests passed).
- The old plan review's concerns about object cap and byte budget are closed by the server caps above.
  Undo authorization and z-order across restart were not re-checked.

One low finding.
**K1. A camera focused full-window on the canvas is not held at the top layer under Balanced or Data saver.**
- The lounge fullscreen and pop-out call holdEnlargedVideo (fullscreen_video_overlay.dart:106, popout_host.dart:60).
  The canvas focus path (canvasFocusedTileProvider -> CanvasFocusedFit, canvas_pane_surface.dart:105-114) never does.
- So the manual cap from layerFor (MEDIUM for Balanced, LOW for Data saver) wins over adaptive stream (track_settings.dart:57-63).
- Shares are only affected under Data saver, where MEDIUM is the full layer anyway.
  Auto and Max are unaffected.
- Change: call ref.read(voiceControllerProvider.notifier).video.holdEnlargedVideo(key) when a canvas tile becomes focused and release it when focus clears, with the release kept in the pane state.
  Add a test that focusing a camera tile under Data saver yields an enlarged key.
- Prove: Data saver, remote 720p camera, expand on the canvas, read frameHeight (180p before, 720p within about 2 s after), with the lounge overlay as control.
- Not checked: the canvas share tile default of 360x203 world units (canvas_presence_geometry.dart:16) was raised as a possible low-layer issue.
  The expand control and layer behaviour at default zoom remain unverified.

## 8. Measurement plan

Do these before the batch ships, so every change goes out with numbers.

1. Fix the harness first: M1 (all profiles recorded, artefact assertion, unit test), M2 (timed_join and the cut stage), M3 (stamp Chrome and libwebrtc versions).
   - Re-run clean, loss5-jitter30 and burst, one invocation per profile until M1 lands, with three repeats and the median, to get a real noise floor.
   - Record the result as the committed baseline.
2. Instrument the product:
   - reconnect lifecycle log lines and counts (R1);
   - the sampler running for senders plus a per-share summary (M4);
   - the echoReturnLoss raw entry plus receive counters (A4);
   - process CPU and worst-frame ms (M7);
   - camera start-bitrate and setup-time logger lines (C8);
   - the one-tap diagnostics copy (M5).
3. Real-hardware runs, owner or QA, not prod:
   - Desktop share size and layer readback on a 1440p/4K display, on Linux (nested kwin, isolated XDG_CONFIG_HOME) and on a Windows PC (S1, M6).
   - Linux desktop receive latency with the sink-monitor chirp for Standard, Strong and Strongest, clean and loss5-jitter30, 20 chirps per cell.
     - mic-handling.md:561 says the desktop number was never measured.
     - The budget from the docs is gate lookahead 20 ms, DFN plus 10 ms, Opus frame 20 ms plus about 6.5 ms lookahead, and jitter buffer 31 to 39 ms clean.
   - Windows: the ducking check, an OEM laptop A/B for the communications category, and weakest-laptop CPU with Strongest.
   - iPhone: the interruption matrix (A5), a 15 minute camera and thermal run (C6), broadcast extension fps and memory (S9), and a mic level check with the platform APM.
4. Network:
   - the owner upstream speed test (N1), then the fan-out test;
   - a relay-only join (N4);
   - a media-path-only cut at 5, 20 and 60 s (R1);
   - LAN pair RTT on the hairpin (N5);
   - the uplink policer arm and a 2 CPU / 512 MiB SFU arm (M7).
5. Prod log tally cron (M7): connectionType, os, connectTime and `ice reconnected` per day.
   Alert on tcp or relay.
6. After the batch, repeat steps 1, 3 and 4 and compare against the baseline within the measured noise floor.
   Refresh the headline tables in voice-quality-harness-v2.md and voice-bursts.md with the Chrome version and commit.

Acceptance targets by item:
- Clean ViSQOL at least 4.3 on both sides and no concealment.
- loss5-jitter30 at least 4.3 and mouth-to-ear under 130 ms.
- Share viewer decoded size equals the intended layer size, and fps is at least 0.9 of requested on a quiet box.
- Camera quality change visible in outbound frameWidth within 2 s of the setting.
- Reconnect banner within about 2 s of ICE disconnected, and cleared on recovery.

## 9. Appendix

### 9.1 Already good (keep)

Audio:
- Mic publish options: RED on (red:false is the right inversion, local.dart:191), DTX off, 48 kbps pinned (audio_publish_options.dart:10-17).
  The prod SFU log confirms audio/red and TF_NO_DTX on all 13 mic tracks.
  Do not trade for 32 kbps or DTX on.
- Capture constraints reach the fork correctly (flutter_media_stream.cc:151-163, 227-234).
  Chain order scrub, NS, gate, dynamics is right, and AEC3 sees the unmodified signal.
- The adaptive jitter buffer behaves (31 to 39 ms clean, 65 to 70 ms at 5% loss).
  Leave playout delay alone.
- Share audio is isolated from the call (a private PipeWire mix on Linux, WASAPI process loopback excluding the app on Windows) and published separately at 96 kbps with DTX and RED off.
- The Windows ducking opt-out exists in the fork (verification pending, see A6).
- Per-person gain uses a cube taper below 100%.
  Silence also disables the publication so the SFU stops forwarding.
  Mute and deafen are re-applied on every room event.
- stopAudioCaptureOnMute false with a 15 s release grace avoids Bluetooth profile flips.
- Gate design is sound on onsets (20 ms lookahead, 5 ms open ramp, 300 ms hold, speech-probability OR; the DFN blend cut clipped starts from 55/168 to 6/168).
- Active-speaker detection is tuned and measured (update_interval 100, smooth_intervals 1, min_percentile 20: 50 to 120 ms to light, 150 to 210 ms to clear).
  Note the SFU default active_level is 35, not 30.
- Stats-driven health thresholds and hysteresis are sourced and do not flicker.
  Replay of recorded burst stats trips the glyph on the worst recording.
  Add cause wording rather than retuning.

Screen share and camera:
- Share fps and bitrate reach the encoder now (screenSharePublishOptionsFor, publishVideoTrack, computeVideoEncodings).
  The prod SFU log declares q 960x540 2 Mbps and h 1920x1080 8 Mbps for the 1080p60 tier.
  Do not revert to setScreenShareEnabled.
- Requested fps reaches the desktop capturer (mandatory.frameRate, flutter_screen_capture.cc:526-530, 701).
- fitScreenShare never raises above the real source or the Space ceiling for tier and bitrate (web path).
- The bitrate table is coherent up to 1080p30 and anchored on LiveKit's own 2 and 5 Mbps, with a 12 Mbps cap so one share cannot take a whole uplink.
- Viewer side: adaptive stream and dynacast are on, enlarged tiles are forced to HIGH for fullscreen and pop-out, Max uses a fixed 16x density (clamped to 3x by the SDK, see C7), shares use contain fit, and the cursor is on by default.
- Linux live quality change does not re-prompt the portal.
  Windows has liveness with 8/16/30 s backoff.
- Camera degradation preference is maintainFramerate on all three platforms.
  The Data saver camera (640x360) is not single-layer (size 640 is at least 480, so h180 plus original).
- Camera bitrate presets are LiveKit's own and match CameraQuality.
  Mirroring is correct.
- Stall watchdog thresholds (3 s / 4 s / 10 s) are sound and handle static shares via needsTraffic.
- Phones pause the camera on background, and camera open is on a worker thread.
- The SFU is not the constraint: docs/sizing.md measured 1 publisher to 30 subscribers at 4.2% of a core.
  The decision should be driven by sender CPU and the host uplink.

Network and resilience:
- Prod LiveKit is healthy (0.29 to 0.44% CPU, 58 MiB of 512 MiB, zero restarts, 0 ERROR lines).
  - 18 RcvbufErrors in 316,323 datagrams, so rmem_max is fine.
  - Ports and TCP 7881 are reachable.
  - Webhooks, ListParticipants and RemoveParticipant work.
  - Join tokens are well formed (120 s TTL, capped at 300 by a compile-time assert, refreshed to 10 min after join).
- The TURN/TLS endpoint is live with a valid certificate on TLS 1.3.
- Reconnect layering is sound (SDK ladder about 44 s, then VoiceAutoRejoin 2/5/10/30 s).
  Mic recovery, device fallback, release grace and the Strong stall refund are deliberate.
  The 15 s heartbeat design is conservative.
- The share e2e (E2E_SHARE_MATRIX) already reads per-rid outbound stats and is the right harness to extend for native rows.

Lounge:
- Speaking ring on the whole tile with a 300 ms hold.
- Mic chip level bar.
- Dock design (decision 0047, do not undo points 1 to 3).
- Semantics and keyboard-focus tooltips.
- Share stage as a black 16:9 card.
- Tile packing for 1 to 12 with a reserved dock height.
- Phones portrait-locked except fullscreen.
- Persistent MicFailureBanner and AppErrorState.
- Quality changes write through the same notifier as Settings.
- Reduce-motion honoured.
- 44 dp hit areas.

### 9.2 Refuted findings (checked, not issues)

1. **Speaking ring may not light for quiet talkers because active_level is 30.** The default is 35 in v1.10.1 (audiolevel.go:43-48), and the SFU tests per-packet level, not a long-term average.
   The local ring uses the input gate reading.
   No measurement of the claimed failure.
2. **Reopen of the muted mic after the 15 s release is unmeasured.** On Linux the engine already drops the source within 0.6 s of any mute, and the reopen costs about 25 ms (mic-handling.md around line 500).
   The app already logs the reopen time.
   A "release when muted" toggle was decided against.
3. **2160p tiers are not feasible and should be removed.**
   - The evidence was a software-canvas harness that the research doc itself discounts.
   - fitScreenShare clamps to the source, prod is capped at 1080, and the 12 Mbps cap is intentional.
   - The start-bitrate hint is capped by the SDK at 1000 kbps.
   - Re-file as "measure native 4K on real hardware" (M6).
4. **iPhone on IPv6-only cellular may find no media path.** Nothing shows libwebrtc failing, and iOS usually runs a CLAT.
   It needs a device test, not a defect.
5. and 7. **Heartbeat eviction at 40 to 50 s races the SDK's 44 s ladder.** LiveKit closes a media-dead participant at about 20 s (ICE failed 15 s plus 5 s cleanup), and a prod example closed in 21 s.
   So the SDK cannot resume past that anyway, and the roster is webhook-driven.
6. **The fork misses the data-channel close fix, so every leave logs a DTLS timeout.** The pin 2dd16a8 is the 1.6.2+hotfix.4 rebase and contains 52274f3, 966485d and 8ecd2e5.
   The rebase doc line is stale.
   The cause of the prod DTLS timeout WARNs is still unexplained (an older prod client, SDK disconnect ordering, or normal SFU behaviour).
8. **iOS interruptions and route changes rely entirely on defaults.** Route changes are forwarded by the fork and followed in Dart, and the sender-stats watchdog runs on iPhone.
   The CallKit part survives as device test A5.
9. **No frozen-capture recovery on Linux share.** The premise is unverified and the proposed Windows-style test cannot work on a static screen.
   It survives as measure-first S10.
10. **Call stage, dock, overlay and phone states have no UI snapshots.** The suites exist (listed in section 6); only a partial gitignored build directory was inspected.
    The narrow part that holds is the isDesktopHost fidelity gap in the phone settings snapshot.
11. **Health thresholds are not calibrated and the worst profile may not trip the glyph.** Replay shows it does trip on the worst recording.
    The valid nit is that one 5 s interval already satisfies the sustain, so the glyph can flap with burst phase.
12. **The sharer is never told about cpu/bandwidth limits because the banner was deleted.** It was deleted on purpose in #2270 in favour of balanced degradation.
    Only the research doc is stale (S12).

### 9.3 Open questions for the owner

- Flip the Space Strong noise suppression flag now, or after a real-voice check?
  (A1)
- Data saver for shares: map to LOW, or keep behaviour and fix the copy?
  (S3)
- Text shares: keep balanced, or split by fps tier or content mode?
  (S4)
- Stereo share audio: go, and accept a patch or fork of livekit_client for TF_STEREO?
  (S5)
- Server-side call quality record: opt-in anonymous aggregates only, or just a copyable diagnostics export?
  (M5)
- Dock design: is a visible entry for share options on phones acceptable within decision 0047's width budget, and which of mute/Leave should lose the shared red outline?
  (section 6 items 1 and 20)
- Hardware tests that only the owner or QA can run:
  - Windows OEM laptop (communications category, enhancements on and off);
  - the Windows ducking check;
  - weakest-laptop CPU with Strongest;
  - the iPhone interruption matrix;
  - a 15 minute iPhone camera run;
  - the iPhone broadcast extension;
  - a real 1440p/4K share readback;
  - the WAN upstream test.
- A relay-only join to prod needs a private test channel (memory rule).
  When is a good window?
- A LiveKit upgrade window for v1.13.11, with a rollback ready.
- Windows VM: is it worth fixing its network (passt or bridged) so a headless Windows client can join an e2e room?

# Voice quality harness v2: MOS, latency, experience timings and the desktop noise path

Written 2026-10-19.
It extends the harness in `voice-quality-harness.md`.
Every number below comes from one local stack (LiveKit v1.10.1 in docker, the same server binary for both sides, headless Chrome listeners, netem on the SFU's egress).
The two client builds differ, the server does not.

## What is new

- Objective quality score per received recording: ViSQOL and DNSMOS, reported next to the anomaly counts.
- Mouth-to-ear latency from timed chirps, separated from the jitter buffer delay that `getStats` reports.
- Experience timings: click-to-join, speaking-ring lag, and recovery after a 10 s network cut.
- A desktop path: the real Linux client, fed by a virtual PipeWire microphone playing speech with fan hum, typing and a dog bark, judged by a browser listener.

## How each part works

### Quality score

- The reference clips are now real speech (piper neural TTS, two voices, `make_speech_clip.py`) because an objective MOS model needs natural speech.
  `E2E_VQ_CLIPS=synthetic` brings back the old synthetic clips.
- ViSQOL (google/visqol at commit 38d0b01, speech mode, 16 kHz) runs from a docker image built with `docker build -f scripts/lib/visqol.Dockerfile -t slimm-visqol:local scripts/lib` (about four minutes).
  It compares each received speech run with the same run of the aligned reference.
  Identical audio scores 4.58, which is the ceiling of speech mode.
- DNSMOS (`speechmos` in a venv, no reference needed) is a cross-check.
  It does not move much with network loss, so ViSQOL is the number to watch.
- The first attempt, on the synthetic clips, showed why real speech matters: DNSMOS scored the received audio above the sent audio and did not separate the profiles.
- The aligner now carries the previous delay forward when the reference is silent, so room noise in a gap cannot drag the alignment.

### Mouth-to-ear latency

- The latency clip carries a 60 ms chirp (1.5 to 3.5 kHz) every 2.1 s, between short phrases.
- The sender page taps its own microphone stream, the receiver taps the decoded remote track, both stamped with one epoch clock (the browsers share a machine).
- A matched filter finds each chirp in both recordings, and each arrival is paired with the latest send before it.
- The jitter buffer delay is the receiver's `jitterBufferDelay / jitterBufferEmittedCount`, shown beside it.
- Not included: the audio output device buffer, and any capture buffer before the page's own stream.
- Checked on a loopback peer connection in one page: 60.4 ms with a spread under 1 ms.

### Experience timings

- Click to join: the page logs the click, then the first remote RTP packet, the first audible energy and the "in call" label, while the other person is already talking.
  The first join of a run is cold, the rest are warm (leave and rejoin).
- Speaking ring: the sender talks after at least 2.5 s of quiet (taken from its own microphone tap), and the listener's semantics tree is watched for "Vqa, speaking".
- Cut: netem `loss 100%` on the SFU's egress for 10 s, then cleared.
  This cuts the downlink only, the uplink keeps flowing.
  The listener's tap, its peer-connection events and the call label say whether audio came back and whether the call had to rejoin.
  The cut and restore instants are taken around the `docker run` that applies them, so they are good to roughly 0.3 s.

### Desktop path

- `client/packages/app/lib/src/diagnostics/voice_harness.dart` joins a voice channel at launch from `--voice-harness-channel=<id>` and prints one status line per second (call state, gate readings, whether rnnoise ran).
- It exists only in a build made with `flutter build linux --release --dart-define=SLIMM_VOICE_HARNESS=true`.
  The flag is a compile-time constant, so every ordinary build drops the code, and `voice_harness_test.dart` pins the default to false.
- `desktop_audio.py` creates a null sink and a remapped virtual source (`slimm_vq_mic`), a second null sink for the app's playback, and a nested `kwin_wayland --virtual --socket wayland-test`.
  The app runs under `dbus-run-session` with its own XDG directories and `PULSE_SOURCE` and `PULSE_SINK` set for itself only.
  The harness seeds a signed-in session and the arm's settings into that directory, checks the app holds no file of the owner's real data directory, and asserts the owner's default devices did not change.
  Everything it creates is removed afterwards.
- The noisy mix (`make_noise_bed.py`) is generated: a fan (mains harmonics plus hiss at -38 dBFS), keyboard typing, and a two-formant dog bark, placed both in silent gaps and over speech.
- The four arms are Strong (rnnoise) on or off against the input gate at its floor (-80 dB, always open) or at the shipped -50 dB.
  The compressor and limiter stay at their default (on).
- `voice_noise.py` aligns the recording to the sent speech and reports, in dB: the hum floor in clean gaps, the change of each noise event, the speech level change, how far noise over speech sits above speech alone, and how many word onsets lose 30 ms or more in their first 200 ms.

## Method for the before and after comparison

- BEFORE is `origin/main` at 274ba3b8e (client 0.114.0 plus the pipe fix, flutter-webrtc c4026c6).
- AFTER is `feat/batch15` at 92c291667 (flutter-webrtc a5d9427, the mic fixes and the rest of the batch).
- Each tree's own web bundle and Linux release bundle were built, with the harness entry point patched into both.
- One server and one copy of the harness served both, and the runs alternated: before, after, then the quality scenario again for before and after.
- Raw results are under `~/.slimm-scratch/tmp/report-ab/before` and `.../after` (`baseline`, `baseline2`, `latency`, `experience`, `desktop`).
- `scripts/lib/voice_ab_report.py <dir> quality|latency|joins|speaking|cut|desktop` prints the tables below.
- Spread is shown as median with p95 and n.
  Where n is 1 the table says so in the text and the number is an observation, not a measurement.

## Results: quality per network profile

Two runs per side, 45 s of two-way speech per profile each, so n is 4 recordings.
ViSQOL is MOS-LQO (ceiling 4.58).
The anomaly counts are summed over the two runs and both directions.

| profile | before ViSQOL | before DNSMOS | before anomalies (sum over runs and both directions) | after ViSQOL | after DNSMOS | after anomalies (sum over runs and both directions) |
|---|---|---|---|---|---|---|
| burst | 4.20 (p95 4.27, n 4) | 3.39 (p95 3.48, n 4) | dropout 11, click 1, static 4, tone 0, clipping 0, level_burst 31 | 4.15 (p95 4.25, n 4) | 3.41 (p95 3.47, n 4) | dropout 6, click 0, static 2, tone 0, clipping 0, level_burst 8 |
| clean | 4.41 (p95 4.43, n 4) | 3.38 (p95 3.42, n 4) | dropout 0, click 0, static 0, tone 0, clipping 0, level_burst 0 | 4.41 (p95 4.42, n 4) | 3.40 (p95 3.42, n 4) | dropout 0, click 0, static 0, tone 0, clipping 0, level_burst 0 |
| loss5-jitter30 | 4.14 (p95 4.20, n 4) | 3.40 (p95 3.44, n 4) | dropout 6, click 2, static 2, tone 0, clipping 0, level_burst 33 | 4.17 (p95 4.33, n 4) | 3.39 (p95 3.46, n 4) | dropout 4, click 1, static 2, tone 0, clipping 0, level_burst 22 |

- A clean call scores 4.41 on both builds with no anomalies.
- Loss costs about 0.25 ViSQOL points at 5% loss with jitter and about 0.2 under burst loss, on both builds.
- AFTER shows fewer anomalies under burst loss (level bursts 8 against 31, dropouts 6 against 11), but netem's random loss differs between runs and the ViSQOL medians are within each other's spread, so this is a hint and not a result.
- DNSMOS stays at 3.4 everywhere: it sees the speech, not the missing milliseconds.

## Results: mouth-to-ear latency

Both directions, about 21 chirps each per run, n is the pooled count.

| profile | before mouth-to-ear ms | before jitter buffer ms | after mouth-to-ear ms | after jitter buffer ms |
|---|---|---|---|---|
| burst | 133 (p95 140, n 42) | 105 | 112 (p95 139, n 42) | 88 |
| clean | 54 (p95 58, n 42) | 33 | 58 (p95 60, n 41) | 33 |
| loss5-jitter30 | 162 (p95 188, n 41) | 120 | 151 (p95 183, n 42) | 107 |

- A clean call takes 54 to 58 ms mouth to ear, of which 33 ms is the receiver's jitter buffer.
  The remaining 20 to 25 ms is capture, encode, network, SFU and decode.
- Loss and jitter raise it to about 150 to 160 ms, almost all of it the jitter buffer growing to 107 to 120 ms.
- The two builds agree within about 10 ms on clean and loss5-jitter30.
- Burst loss is 112 ms after and 133 ms before, with the p95 about the same (139 against 140), so the median difference is not clear.

## Results: joining, speaking ring and the cut

Join: 8 joins per side, the first cold and 7 warm.

| click to | before cold ms | before warm ms | after cold ms | after warm ms |
|---|---|---|---|---|
| 'in call' shown | 400 | 105 (p95 111, n 7) | 397 | 95 (p95 107, n 7) |
| first remote packet | 552 | 283 (p95 339, n 7) | 548 | 276 (p95 329, n 7) |
| first audible audio | 647 | 390 (p95 1245, n 7) | 648 | 451 (p95 1458, n 7) |

- A warm join shows "in call" about 100 ms after the click and receives the first packet after about 280 ms.
  A cold join takes about 400 and 550 ms.
- "First audible" depends on the speaker being mid-word, and the speech clip has pauses, so its p95 of 1.2 to 1.5 s is the clip's pauses and not the call.
- The two builds are the same within the spread.

Speaking ring lag (speech onset to the ring lighting, listener side):

| profile | before ms | after ms |
|---|---|---|
| burst | 440 (p95 440, n 1, missed 0) | 669 (p95 737, n 6, missed 0) |
| clean | 536 (p95 1030, n 9, missed 0) | 497 (p95 531, n 6, missed 0) |
| loss5-jitter30 | 670 (p95 774, n 7, missed 0) | 577 (p95 910, n 7, missed 0) |

- The ring lights 0.5 to 0.7 s after speech starts.
  The burst row for BEFORE has a single sample, so that cell says nothing.

Recovery after a 10 s cut (one cut per side, so n is 1 and the audio times depend on where the speech clip's pauses fell):

| measure | before | after |
|---|---|---|
| first packet after link back ms | 147 | 298 |
| first audio after link back ms | 117 | 1303 |
| audio heard during outage s | 0.0 | 0.0 |
| full rejoin | False | False |
| call still open | True | True |
| ice_disconnected_ms after cut | 7626 | 7412 |
| ice_connected_ms after cut | 11079 | 10443 |

- Both builds recovered without a rejoin: no new peer connection appeared, the call stayed open, and ICE went disconnected about 7.5 s into the cut and connected again within 1 s of the link coming back.
- Packets resumed 150 to 300 ms after the link came back.
- The 117 ms against 1303 ms to first audio is not a difference between builds: it is the next word starting, and one sample cannot show it.
  A repeat with more cuts is needed before saying anything about recovery speed.

## Results: desktop noise path

`hum floor` is the change of the fan's level in clean gaps (negative is quieter).
`speech` is the change of speech level against the speech alone.
`clipped onsets` is how many word starts lost 30 ms or more in their first 200 ms, out of the word starts measured (about 10 per recording, 60 s each).

| arm | network | before hum floor dB | before speech dB | before clipped onsets | before onset lost ms | after hum floor dB | after speech dB | after clipped onsets | after onset lost ms |
|---|---|---|---|---|---|---|---|---|---|
| standard-gate-off | clean | -18.3 | 0.9 | 0/11 | 8 | -18.6 | 1.3 | 0/10 | 9 |
| standard-gate-off | loss5-jitter30 | -16.7 | 0.9 | 1/10 | 15 | -17.9 | 1.0 | 3/10 | 20 |
| standard-gate-off | burst | -19.0 | 0.8 | 5/11 | 30 | -17.9 | 1.2 | 1/10 | 15 |
| standard-gate-on | clean | -17.7 | 1.1 | 0/10 | 6 | -17.3 | 1.2 | 1/11 | 12 |
| standard-gate-on | loss5-jitter30 | -20.0 | 0.7 | 1/10 | 12 | -17.9 | 0.8 | 3/10 | 18 |
| standard-gate-on | burst | -18.5 | 0.9 | 3/10 | 17 | -17.9 | 1.0 | 1/10 | 13 |
| strong-gate-off | clean | -68.2 | 0.9 | 1/11 | 4 | -68.6 | 0.8 | 1/11 | 3 |
| strong-gate-off | loss5-jitter30 | -66.1 | 0.3 | 2/11 | 9 | -67.2 | 0.5 | 3/11 | 16 |
| strong-gate-off | burst | -67.9 | -0.1 | 3/10 | 11 | -67.5 | 0.7 | 4/11 | 17 |
| strong-gate-on | clean | -20.8 | 0.6 | 0/10 | 3 | -11.1 | 0.8 | 2/10 | 8 |
| strong-gate-on | loss5-jitter30 | -68.0 | 0.4 | 1/10 | 8 | -68.6 | 0.4 | 5/10 | 17 |
| strong-gate-on | burst | -68.4 | 0.3 | 2/10 | 19 | -68.1 | 0.4 | 3/10 | 17 |

Noise events in the gaps, from the same runs, `typing` and `bark` in dB change (0 means passed through untouched):

| arm | build | typing in gap, clean / loss5 / burst | bark in gap, clean / loss5 / burst |
|---|---|---|---|
| standard-gate-off | before | -7.7 / -6.7 / -7.5 | 0.4 / 1.5 / 0.0 |
| standard-gate-off | after | -7.1 / -7.4 / -7.4 | 0.9 / 0.1 / 0.6 |
| standard-gate-on | before | -7.0 / -7.4 / -6.6 | 0.1 / 0.8 / -0.5 |
| standard-gate-on | after | -6.5 / -7.0 / -7.6 | 0.7 / 0.3 / 0.5 |
| strong-gate-off | before | -23.3 / -20.5 / -49.6 | 0.4 / -0.3 / 0.6 |
| strong-gate-off | after | -28.1 / -40.4 / -36.1 | 0.4 / 0.2 / 0.4 |
| strong-gate-on | before | -72.2 / -21.4 / -20.1 | 0.3 / 0.6 / 0.4 |
| strong-gate-on | after | -72.0 / -71.3 / -67.8 | 0.4 / 0.5 / 0.4 |

- Strong takes the steady fan from -18 dB to about -68 dB, against -18 dB for Standard.
  The speech level moves by about +1 dB in every arm, so speech is kept.
- A dog bark in a gap comes through at its full level in every arm of both builds (within 1.5 dB).
  Neither Strong nor the -50 dB gate removes it.
- Typing is where the builds differ.
  Standard takes it down by about 7 dB, Strong by 20 to 50 dB, and Strong with the gate on by about 70 dB, but only reliably on AFTER: BEFORE reached -72 dB on the clean network and only -20 dB on the two lossy ones, AFTER held -68 to -72 dB on all three.
- Over speech, nothing separates the noise from the voice.
  On BEFORE the bark sits 1.8 to 2.7 dB above the speech alone, as sent (2.5 dB), and typing sits level with it.
  On AFTER the bark sits 0.4 to 1.5 dB above speech, so it is trimmed by about 1 to 2 dB, and typing stays within 1.3 dB of speech.
- Word onsets lose about 10 to 20 ms on average, and 0 to 5 of 10 are clipped by 30 ms or more.
  Under loss the Standard arms clip as many onsets as the Strong ones, so a good part of it is concealment and not the suppressor.
  The Strong arms on AFTER clip more under loss than BEFORE (strong-gate-on loss5: 5 of 10 against 1 of 10, mean 17 against 8 ms; strong-gate-off burst: 4 of 11 against 3 of 10).
  With n of about 10 per cell I would read that as a possible regression to re-measure, not a finding.

## What to fix first

1. Non-stationary noise.
   A dog bark passes through at full level with Strong on and the gate on, and typing is only removed in the gaps.
   If this matters, it is the largest remaining gap between what the setting promises and what a listener hears.
2. Strong with the gate on on BEFORE did not hold typing suppression on lossy networks (-20 dB against -72 dB clean) while AFTER does.
   That is an improvement to keep, and a reason to keep the gate hold logic covered by the desktop scenario.
3. Word onsets under Strong on AFTER under loss.
   Re-measure with more samples (the harness takes `E2E_DESKTOP_SECONDS`), then look at the gate lookahead.
4. Loss costs 0.2 to 0.25 ViSQOL points and 100 ms of mouth-to-ear delay at 5% loss with jitter.
   The delay is the jitter buffer, so any gain has to come from the buffer's target, not from the codec path (20 to 25 ms).
5. Level bursts and dropouts under burst loss, as found in the first harness document, are still there on both builds.

## Not verified

- Windows and macOS clients, and real headsets, microphones and speakers: the desktop path is Linux only, through a virtual microphone.
- Uplink loss: netem shapes only what the SFU sends, so the cut and the profiles are downlink conditions.
- Playout: latency stops at the decoded track, not the loudspeaker.
- The recovery after a cut is one observation per build.
- The server was the same for both sides, so nothing here says anything about server changes in `feat/batch15`.
- DNSMOS and ViSQOL were run on TTS speech, not on people.

## Join token prefetch (removed)

An earlier branch minted the voice token on hover and held it for 30 seconds.
It was removed before it shipped, and the join asks for its token at click time again.
The cache was keyed by channel only and outlived a sign-out on a shared device, so the next account could be handed the previous account's token.
A prefetched token also skipped the server's room lock and user limit checks for up to 30 seconds, because those run only when a token is minted.
The saving was never measured, so it did not justify either cost.
The join timing marks (`tokenRequested`, `tokenReceived`) stay and show the round trip.

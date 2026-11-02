<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Mouth and desk sounds through Strong noise suppression (2026-11-02)

The owner's report: "even though I have strong suppression on, things like swallowing or chewing or background noise make it through, even louder than they would normally."
This note records what was measured on 2026-11-01 and 2026-11-02 against the v120 client (origin/main 3cce41eee, flutter_webrtc fork 2dd16a8, livekit_client 2.13.1), what was found, and what the new harness scenario asserts.

## Result in short

1. Strong was not running at all after a restart.
   `restoreNoiseSuppression` loaded the saved choice and left applying it to the Space default read, which returns early when the default has not changed from Standard.
   On a Space that defaults to Standard, which prod does, a saved Strong or Strongest never reached the native chain until the picker was touched in that session.
   The first real-client run of the new scenario showed it: the Strong arm logged rnnoise on 0% of gate readings and scored the same as Standard.
   Fixed in `voice_input_settings.dart` with a regression test (`a saved Strong reaches the session on launch when the Space defaults to Standard`).
2. With rnnoise actually running, what it removes depends on how loud the sound is against the voice.
   At a desk level (event energy about 17 dB under the voice) it removes three of four chewing clips by 36 to 40 dB, lip smacks by 18 to 24 dB, swallows by 20 to 40 dB and a breath by 53 dB.
   At microphone level (peaks 6 dB under full scale) the same sounds lose only 4 to 9 dB, and a cough or wet chewing passes at -3 to -4 dB with rnnoise's speech probability pinned at 1.0, so the input gate opens for them.
3. Nothing in the native chain makes a sound louder.
   The worst aligned 10 ms frame in every rnnoise run is within +0.5 dB of what went in.
   libwebrtc's auto gain, which runs before the chain, lifted an isolated gap sound by about 2 dB in the Standard arm of the real-client run, and its fixed lift pushes quiet mouth sounds up into the level band where rnnoise stops removing them.
   The "louder than normal" the owner hears is that lift plus the contrast of a removed floor; whether turning auto gain off under Strong is a net win is what the `strong-agc-off` arm measures.
4. DeepFilterNet does not help with the loud cases.
   Its attenuation limit and floor settings (`DFN_ATTEN` 60 or 100, `DFN_MIN_DB` 0 or -20) move wet chewing by less than 1 dB.

## How it was measured

Three layers, cheapest first.

- Offline, the fork's `test/native/strongest_tool` run by `scripts/research/mouth_transients_offline.py`: the suppressor alone, no libwebrtc processing around it.
  It reports per event the energy change, the loudest aligned frame, rnnoise's speech probability and the share of frames the input gate (modelled from `flutter_input_gate.cc`) would open.
- A corpus of 15 recorded CC0 clips (chewing x4, swallowing x3, lip smacks x3, a breath, a sip, mouse clicks, a chair creak, a cough), listed with source, author and sha256 in `scripts/lib/mouth_noise_manifest.json` and rebuilt by `scripts/lib/fetch_mouth_noise.py`.
  No audio is committed.
  The synthetic set in `make_noise_bed.py` (a lip smack, six crunches, a gulp, an exhale) stands in when the corpus is absent.
- End to end, the real Linux client in the desktop harness: `E2E_PAR_OPT_IN=1 E2E_ONLY="voice transients" bash scripts/e2e-parallel.sh`, which runs Standard, Strong, Strong with auto gain off, and Strongest on a clean network and scores each event as sent against as heard (`scripts/lib/e2e_voice_transients.py`).
  It fails when a gap event comes out louder than it went in (1 dB, or 3 dB in arms that keep auto gain on) or speech moves more than 3 dB.

## Offline: recorded clips through rnnoise (Strong)

Each clip is laid in a silent tail after piper speech, so rnnoise has adapted to a voice.
`in` is the clip's energy over its frames in dBFS on the capture scale, `change` is out minus in, `p max` is the highest speech probability rnnoise reported during the clip, `gate` the share of its frames the input gate would open.
The voice sits at about -20 dBFS.

Clip gain -18 dB (a desk level):

| clip | in dB | change dB | p max | gate open |
|---|---|---|---|---|
| chew (chips) | -38.4 | -39.9 | 0.10 | 0.00 |
| chew (cereal) | -38.4 | -36.4 | 0.35 | 0.00 |
| chew (crispbread) | -38.4 | -38.5 | 0.16 | 0.00 |
| chew (apple, wet) | -35.8 | -7.0 | 1.00 | 0.28 |
| swallow x3 | -38.4 | -24.1 / -40.3 / -19.7 | 0.77 / 0.32 / 0.60 | 0.03 / 0.00 / 0.00 |
| lip smack x3 | -38.2 | -22.8 / -18.3 / -23.5 | 0.72 / 0.98 / 0.88 | 0.01 / 0.05 / 0.01 |
| breath | -37.4 | -52.6 | 0.01 | 0.00 |
| sip | -38.0 | -40.5 | 0.12 | 0.00 |
| mouse click | -36.5 | -36.2 | 0.32 | 0.00 |
| chair creak | -37.8 | -25.9 | 0.88 | 0.04 |
| cough | -37.9 | -13.1 | 0.99 | 0.27 |

Clip gain 0 dB (peaks at -6 dBFS, a mouth at the microphone):

| clip | in dB | change dB | p max | gate open |
|---|---|---|---|---|
| chew (chips) | -37.9 | -31.3 | 0.40 | 0.00 |
| chew (cereal) | -37.2 | -16.0 | 0.99 | 0.08 |
| chew (crispbread) | -36.5 | -23.0 | 0.98 | 0.05 |
| chew (apple, wet) | -21.1 | -4.2 | 1.00 | 0.47 |
| swallow x3 | -34.5 / -35.0 / -31.7 | -7.0 / -23.2 / -5.7 | 1.00 / 0.96 / 1.00 | 0.20 / 0.03 / 0.23 |
| lip smack x3 | -30.0 / -32.3 / -34.4 | -25.2 / -6.9 / -6.0 | 0.93 / 1.00 / 1.00 | 0.04 / 0.22 / 0.22 |
| breath | -25.8 | -18.5 | 0.99 | 0.03 |
| sip | -29.3 | -9.6 | 1.00 | 0.20 |
| mouse click | -22.8 | -8.7 | 1.00 | 0.15 |
| chair creak | -27.7 | -8.2 | 1.00 | 0.16 |
| cough | -28.3 | -3.3 | 1.00 | 0.56 |

The -6 dB rows sit between the two.
Strongest (DeepFilterNet blended with rnnoise) is within 3 dB of Strong on every loud row and sometimes worse on the quiet ones (a sip -27 dB against -40 dB).

## Offline: the synthetic set

The synthetic crunches peak at -20 dBFS and read as speech to rnnoise (probability 1.0 on every crunch): -1.2 dB in a gap, with the gate opening for each bite and holding 300 ms.
The synthetic bark passes the same way (-0.7 dB), as `voice-quality-harness-v2.md` already found.
The synthetic lip smack (-52 dB), breath (-25 dB), swallow (-15 dB) and typing (-27 dB) are removed.
So the synthetic set is a harder test than most of the recordings for chewing and an easier one for everything else; the scenario prefers the recordings.

## Real client

The first run (2026-11-01, build from origin/main 3cce41eee) exposed the launch bug above: the Strong arm reported `strong=0` on every gate reading and scored within 1 dB of Standard on every event.
Standard itself, with libwebrtc's suppressor and auto gain, took the synthetic chewing in a gap down 11 dB, the smack 16 dB, the breath 23 dB and the swallow 8 dB, left the bark at +0.8 dB, and lifted the bark's loudest frame by 2.2 dB over what was sent.

The second run (2026-11-02, the same tree plus the launch fix) had rnnoise on 100% of readings in the three Strong arms.
The recorded clips were cut to their loudest 1.5 s and laid 12 dB under their -6 dBFS peak; the voice is piper at about -20 dBFS; one 60 s recording per arm.
`change` is the event's energy as heard minus as sent, `worst` the loudest aligned 10 ms frame's change, `speech` the median change of the voice.

| arm | speech | hum floor | chew gap | smack gap | swallow gap | breath gap | bark gap | worst gap frame |
|---|---|---|---|---|---|---|---|---|
| standard (libwebrtc only) | +1.0 | -21.9 | +3.2 | -1.8 | -11.4 | -7.9 | +1.9 | +7.5 |
| strong, auto gain on | +0.9 | -75.2 | +2.2 | -6.0 | -76.6 | -22.0 | +1.9 | +5.5 |
| strong, auto gain off | -1.3 | -75.2 | -2.3 | -11.6 | -76.6 | -82.8 | -1.2 | +2.5 |
| strongest, auto gain on | -0.9 | -73.2 | +2.4 | -75.9 | -74.5 | -81.0 | +1.1 | +8.0 |

Read across the chewing column: with auto gain on, Strong sends chewing 2.2 dB louder than it went in, Standard 3.2 dB louder.
With auto gain off the same chain takes it 2.3 dB down, the lip smack twice as far, and the breath from -22 dB to the floor.
Speech costs 2.2 dB for turning auto gain off at this input level; the 2026-10-28 P5 measurement found up to 12 dB at a quiet input, so the chain has to level after suppression when auto gain goes.
Word onsets clipped 1 to 2 of 10 in every arm, no worse than the Standard arm.

## What to change

- The launch fix ships in v121 (`fix(voice): apply the saved noise suppression choice on launch`).
- The scenario is the regression test for the rest: once the Strong arm is measured with rnnoise running, its gap-event changes become the ratchet, with the recorded corpus as the fixture.
- Auto gain under Strong is decided by the `strong-agc-off` arm, not by argument: if quiet mouth sounds are removed 10 dB or more deeper with it off and speech level is held by the chain's own dynamics, Strong should turn it off and level after suppression; if not, leave it.
- Loud mouth sounds at the microphone are a model limit.
  rnnoise and DeepFilterNet both read them as voice.
  A card covers evaluating a newer small model trained on the DNS mouth-noise categories; nothing in the gate or the dynamics can fix it, and a stricter gate would clip word starts.
- The owner's own microphone is the missing fixture.
  A 60 second raw recording (room tone, talking, chewing, a swallow, typing) from the headset he uses would replace the freesound previews with the real thing and can be added to the corpus folder as `chew-owner.wav` and friends without committing it.

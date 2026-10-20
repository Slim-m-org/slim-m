# Voice corpus results

Written 2026-10-20 on `test/b16-voice-corpus` (base `feat/batch15`), web client with livekit_client 2.13.1, LiveKit server v1.10.1.
Raw JSON: `~/.slimm-scratch/tmp/report-ab/corpus/` (`before` = origin/main, `after` = feat/batch15, `desktop*` = the Linux client runs).
Everything below is one or two runs per cell, so differences of a few counts are noise.

## Result

- RED plus DTX off cuts loud bursts for every voice type under loss, not only for the two piper voices.
- All 31 clips, burst profile, two runs each: 342 bursts today, 57 shipped; loss5-jitter30, one run: 54 today, 4 shipped.
- Dropouts on a clean network fall from 38 to 6 (DTX was cutting quiet speech, mostly the high female and the slow reader).
- ViSQOL moves by 0.1 or less on most categories; clean is unchanged to within 0.1.
- Worse under the burst profile (long loss runs), in both runs: laughter, loud oratory, speech over music, and dropouts on the 90 s monologue.
- The +6 dB peak over the reference reappeared once (a non-native English speaker, burst profile, shipped, run 1) and not in run 2.
- The DTX tone burst does not occur on real singing or humming, with or without DTX; it is not confirmed or refuted on real voices.
- Suppression keeps speech level (0 to +4 dB), but word onsets are clipped far more often for the corpus voices than for piper, in every arm including Standard.
- Strong removes the hum floor for piper (-60 to -75 dB) but only -2 to -13 dB for most corpus voices.

## Corpus

31 clips, 2 reels of about 5.5 and 6.2 minutes, 48 kHz mono, active speech level from -36 to -17 dBFS.
No audio is committed: `scripts/lib/voice_corpus_manifest.json` holds source URLs, licences, attribution, cut offsets and sha256 (sources and outputs).
`python3 scripts/lib/fetch_voice_corpus.py` rebuilds it into `~/.slimm-scratch/tmp/voice-corpus/clips`; point `E2E_VQ_CORPUS` at that folder.
Without the variable the harness keeps its piper clips.

| clip | category | source | licence | s | active dBFS |
|---|---|---|---|---|---|
| vctk-p254-low-male | low-voice | VCTK | CC BY 4.0 | 19 | -22.0 |
| vctk-p310-high-female | high-voice | VCTK | CC BY 4.0 | 23 | -25.0 |
| vctk-p234-scottish-f | accent | VCTK | CC BY 4.0 | 19 | -26.0 |
| vctk-p248-indian-f | accent | VCTK | CC BY 4.0 | 24 | -21.0 |
| vctk-p251-indian-m | accent | VCTK | CC BY 4.0 | 19 | -29.0 |
| vctk-p245-irish-m | accent | VCTK | CC BY 4.0 | 22 | -24.0 |
| vctk-p314-south-african-f | accent | VCTK | CC BY 4.0 | 18 | -23.0 |
| vctk-p280-french-nonnative-f | accent | VCTK | CC BY 4.0 | 21 | -27.0 |
| cc0-mark-cousins-uk | accent | Wikimedia Commons | CC0 | 17 | -25.0 |
| bysa-keith-nugent-au | accent | Wikimedia Commons | CC BY-SA 4.0 | 8 | -24.0 |
| vctk-p257-fast-f | fast | VCTK | CC BY 4.0 | 15 | -23.0 |
| vctk-p284-fast-m | fast | VCTK | CC BY 4.0 | 15 | -27.0 |
| vctk-p297-slow-f | slow | VCTK | CC BY 4.0 | 23 | -26.0 |
| librivox-austen-monologue | monologue | LibriVox | Public domain | 90 | -24.0 |
| librivox-esopo-spanish | non-english | LibriVox | Public domain | 25 | -23.1 |
| librivox-laura-german | non-english | LibriVox | Public domain | 20 | -28.0 |
| librivox-artofwar-mandarin | non-english | LibriVox | Public domain | 25 | -26.0 |
| cc0-whisper | soft | Wikimedia Commons | CC0 | 12 | -36.0 |
| pd-roosevelt-infamy | loud | Commons (Library of Congress, NARA) | Public domain | 25 | -16.9 |
| pd-bryan-cross-of-gold | loud | Commons (1920s recording) | Public domain | 25 | -17.0 |
| by-lonemonk-laughter | laughter | Wikimedia Commons | CC BY 3.0 | 10 | -22.0 |
| cc0-twinkle-sung | singing | Wikimedia Commons | CC0 | 20 | -21.0 |
| by-lupita-soprano | singing | Wikimedia Commons | CC BY 3.0 | 22 | -19.0 |
| pd-shenandoah-choir | singing | Wikimedia Commons | Public domain | 20 | -22.0 |
| cc0-woman-humming | humming | Wikimedia Commons | CC0 | 20 | -30.0 |
| mix-crosstalk-overlap | crosstalk | mix of VCTK | CC BY 4.0 | 24 | -24.0 |
| mix-crosstalk-interrupt | crosstalk | mix of VCTK + LibriVox | CC BY 4.0 | 24 | -24.0 |
| mix-speech-over-band | speech-over-music | mix of VCTK + Commons (US Navy Band) | CC BY 4.0 | 24 | -24.0 |
| mix-speech-over-band-2 | speech-over-music | mix of LibriVox + Commons (US Navy Band) | Public domain | 30 | -24.0 |
| librivox-moby-breaths | breaths | LibriVox | Public domain | 22 | -25.0 |
| librivox-huckfinn-breaths | breaths | LibriVox | Public domain | 20 | -27.0 |

- VCTK clips are three consecutive read sentences of one speaker, joined with 0.3 s of silence.
- Accents covered: Scottish, Indian (two), Irish, South African, British, Australian, and a French speaker of non-English-first English.
- The whisper is a 2.6 s CC0 recording repeated four times; it is the only whisper found under a usable licence.
- The Australian clip is 8 s and share-alike; it is used internally and not redistributed.
- Crosstalk and speech over music are mixes of two licensed sources, not recorded events; the music is a US Navy Band instrumental.
- The breath clips were picked by a pause-noise detector, and the pitch, rate and "loud" labels by measurement or description, not by listening.
- I have not listened to any clip.

## Method

- One reel per speaker loops through the call; the received recording is aligned once and every sample is attributed to its clip.
- Cells are `bursts / dropouts / ViSQOL / worst peak over the reference (dB)`; ViSQOL is speech mode, so it is only a relative number for singing, laughter and music.
- today = origin/main web build, shipped = feat/batch15 web build (RED on, DTX off); same harness tree and server.
- Both senders record at once for one full pass of the longer reel plus 8 s.
- Received bitrate: about 43 kbps today and 87 to 93 kbps shipped.

## Speech quality per category

### burst, two runs pooled

| category | today | shipped |
|---|---|---|
| low-voice | 18 / 12 / 3.99 / +1.1 | 5 / 3 / 4.17 / +1.1 |
| high-voice | 22 / 29 / 4.09 / -0.5 | 4 / 12 / 4.09 / +1.2 |
| accent | 100 / 47 / 4.12 / +1.1 | 17 / 27 / 4.12 / +6.0 |
| non-english | 35 / 10 / 3.90 / +0.2 | 4 / 12 / 3.95 / +0.3 |
| monologue | 25 / 10 / 4.36 / +0.1 | 2 / 27 / 4.25 / -0.2 |
| fast | 19 / 9 / 4.13 / +0.5 | 2 / 4 / 4.21 / +0.4 |
| slow | 9 / 29 / 4.42 / +0.1 | 5 / 7 / 4.28 / +0.1 |
| soft | 0 / 0 / 4.20 / +0.4 | 0 / 0 / 4.17 / +0.2 |
| loud | 30 / 8 / 3.97 / +0.6 | 2 / 16 / 3.74 / +0.3 |
| laughter | 3 / 0 / 4.00 / -0.5 | 1 / 4 / 3.28 / -0.3 |
| singing | 11 / 7 / 4.37 / +0.2 | 4 / 7 / 4.21 / +0.2 |
| humming | 4 / 1 / 4.65 / +0.2 | 0 / 1 / 4.57 / +0.2 |
| crosstalk | 21 / 7 / 4.06 / -0.4 | 8 / 8 / 4.17 / -0.1 |
| speech-over-music | 20 / 6 / 4.07 / +0.7 | 1 / 11 / 3.83 / +0.5 |
| breaths | 25 / 8 / 4.10 / +0.5 | 2 / 8 / 3.85 / +0.5 |
| all clips | 342 bursts, 183 dropouts | 57 bursts, 147 dropouts |

### loss5-jitter30, one run

| category | today | shipped |
|---|---|---|
| low-voice | 1 / 2 / 4.19 / +1.1 | 0 / 0 / 4.49 / +1.0 |
| high-voice | 1 / 8 / 4.42 / -0.7 | 0 / 2 / 4.41 / -0.5 |
| accent | 31 / 21 / 4.31 / +1.0 | 3 / 1 / 4.44 / +0.8 |
| non-english | 0 / 0 / 4.17 / +0.2 | 0 / 0 / 4.44 / -0.1 |
| monologue | 0 / 0 / 4.49 / -0.3 | 0 / 0 / 4.63 / -0.6 |
| fast | 5 / 3 / 4.31 / +0.5 | 0 / 0 / 4.47 / +0.4 |
| slow | 4 / 9 / 4.44 / -0.1 | 1 / 1 / 4.67 / +0.4 |
| soft | 0 / 0 / 4.33 / +0.5 | 0 / 0 / 4.17 / +0.3 |
| loud | 8 / 0 / 4.06 / +0.3 | 0 / 0 / 4.30 / +0.3 |
| laughter | 0 / 0 / 4.10 / -0.1 | 0 / 0 / 4.00 / -0.3 |
| singing | 0 / 0 / 4.45 / +1.1 | 0 / 0 / 4.39 / -0.1 |
| humming | 0 / 0 / 4.68 / +0.3 | 0 / 0 / 4.75 / +0.2 |
| crosstalk | 0 / 0 / 4.29 / -0.1 | 0 / 1 / 4.41 / -0.1 |
| speech-over-music | 0 / 0 / 4.46 / +0.5 | 0 / 0 / 4.58 / +0.1 |
| breaths | 4 / 0 / 4.20 / +0.5 | 0 / 0 / 4.33 / +0.4 |
| all clips | 54 bursts, 43 dropouts | 4 bursts, 5 dropouts |

### clean, one run

| category | today | shipped |
|---|---|---|
| low-voice | 0 / 4 / 4.55 / +1.1 | 0 / 0 / 4.51 / +1.0 |
| high-voice | 0 / 17 / 4.54 / -0.4 | 0 / 5 / 4.56 / -0.5 |
| accent | 0 / 5 / 4.45 / +0.7 | 0 / 0 / 4.49 / +0.9 |
| non-english | 0 / 0 / 4.37 / +0.0 | 0 / 0 / 4.43 / +0.1 |
| monologue | 0 / 0 / 4.65 / -0.3 | 0 / 0 / 4.65 / +0.1 |
| fast | 0 / 2 / 4.39 / +0.5 | 0 / 0 / 4.46 / +0.3 |
| slow | 0 / 10 / 4.49 / -0.2 | 0 / 1 / 4.57 / +0.1 |
| soft | 0 / 0 / 4.20 / +0.2 | 0 / 0 / 4.17 / +0.4 |
| loud | 0 / 0 / 4.30 / +0.4 | 0 / 0 / 4.33 / +0.2 |
| laughter | 0 / 0 / 4.30 / -0.2 | 0 / 0 / 4.27 / -0.5 |
| singing | 0 / 0 / 4.58 / +0.1 | 0 / 0 / 4.55 / +0.3 |
| humming | 0 / 0 / 4.77 / +0.2 | 0 / 0 / 4.77 / +0.2 |
| crosstalk | 0 / 0 / 4.37 / -0.1 | 0 / 0 / 4.56 / -0.3 |
| speech-over-music | 0 / 0 / 4.60 / +0.3 | 0 / 0 / 4.60 / +0.5 |
| breaths | 0 / 0 / 4.42 / +0.4 | 0 / 0 / 4.43 / +0.2 |
| all clips | 0 bursts, 38 dropouts | 0 bursts, 6 dropouts |

## Where shipped is worse

Burst profile, two runs each (today / shipped):

| clip type | bursts | dropouts | ViSQOL |
|---|---|---|---|
| laughter | 3 / 1 | 0 / 4 | 4.00 / 3.28 |
| loud oratory | 30 / 2 | 8 / 16 | 3.97 / 3.74 |
| speech over music | 20 / 1 | 6 / 11 | 4.07 / 3.83 |
| 90 s monologue | 25 / 2 | 10 / 27 | 4.36 / 4.25 |
| breaths | 25 / 2 | 8 / 8 | 4.10 / 3.85 |

- The same direction in both runs for laughter, loud oratory, speech over music and the monologue's dropouts.
- Soft voice and humming: no difference anywhere. Singing: bursts down, dropouts equal.
- Clean and loss5-jitter30 show no category that is worse beyond 0.2 ViSQOL; the largest is the whisper under loss (4.33 to 4.17, one run).
- RED does not help long loss runs, which matches the earlier note; the extra dropouts there may be the cost of RED packets arriving late instead of concealment.

## Desktop noise suppression (Linux client, clean network, one 60 s recording per cell)

Cell: speech level change dB / hum floor change dB / onsets clipped of total (mean ms lost).

| voice | Standard gate off | Standard gate on | Strong gate off | Strong gate on |
|---|---|---|---|---|
| piper (reference) | +1.1 / -17 / 1 of 10 (8) | +1.3 / -18 / 2 of 11 (16) | +0.7 / -60 / 2 of 10 (9) | +0.6 / -75 / 1 of 11 (9) |
| low male (VCTK p254) | +0.3 / -19 / 5 of 10 (21) | +0.5 / -19 / 3 of 10 (23) | +0.6 / -13 / 4 of 10 (16) | +0.5 / -9 / 2 of 10 (12) |
| high female (VCTK p310) | +3.1 / -15 / 6 of 11 (51) | +3.5 / -16 / 8 of 10 (46) | +3.7 / -4 / 5 of 9 (38) | +3.7 / -8 / 5 of 10 (35) |
| Scottish female (VCTK p234) | +2.8 / -14 / 4 of 12 (40) | +2.5 / -15 / 5 of 12 (30) | +4.0 / -3 / 2 of 11 (18) | +3.6 / -5 / 1 of 12 (13) |
| whisper | +3.9 / -14 / 0 of 7 (10) | +3.2 / -14 / 0 of 6 (8) | +2.0 / -7 / 4 of 6 (43) | +2.1 / -2 / 1 of 7 (17) |
| sung melody | +1.0 / -13 / 5 of 13 (52) | +2.0 / -16 / 2 of 11 (22) | +2.5 / -76 / 1 of 12 (16) | not recorded |

- Speech level never drops; it rises 0 to 4 dB, so the "keeps speech level" conclusion holds.
- Onset clipping (30 ms or more) is 1 to 2 of 10 for piper and 2 to 8 of 10 for the corpus voices, already in Standard with the gate off, so it is not the gate or Strong.
- Strong adds clipping for the whisper (4 of 6 with the gate off, 43 ms mean).
- Strong's hum reduction for corpus voices is far below piper's; the sung melody (-76 dB) is the exception. I did not find why; the piper clip is louder against the fixed noise bed, which may be part of it.
- The sung melody's Strong gate-on arm never signed in (`SLIMM_HARNESS signin-timeout`), twice; the harness now retries a join failure once.

## Do the batch 15 conclusions hold

- RED plus DTX off reduces loud bursts under loss: yes, for all 15 categories, 342 to 57 on the burst profile.
- DTX off fixes quiet-speech dropouts on a clean link: yes (38 to 6).
- Not worse for soft voices or singing: held, with the whisper under loss at -0.16 ViSQOL, one run.
- Worse: laughter, loud oratory, speech over music and the long monologue under long loss runs.
- The DTX tone fix: unverified on real voice, since no real singing or humming clip produced a burst even with DTX on.
- Suppression keeps speech level: yes.
- Onset clipping: not fine for real voices; the piper figure understates it by a factor of two to five.

## Unverified

- One or two runs per cell, one host, netem on the SFU egress only.
- No clip was listened to; categories rest on source descriptions and measurements.
- Whisper is a repeated 2.6 s sample; the soft category has one clip.
- ViSQOL speech mode on singing, laughter and music is only a relative number.
- Desktop cells are single recordings; the high female's 5 to 8 clipped onsets and the Strong hum figures need a repeat.
- Common Voice was not used (it is now behind a login), so no clip comes from it.
- Windows and macOS clients were not run.

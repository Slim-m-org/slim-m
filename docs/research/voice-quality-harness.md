# Voice quality harness and findings

Written 2026-10-19 against `origin/main` at b2dabe21b, web client, livekit_client 2.13.1, LiveKit server v1.10.1.

## What the harness is

`E2E_ONLY="voice quality" scripts/e2e.sh` joins two browsers, `vqa` and `vqb`, into one local call.
Each captures a different reference clip through Chrome's fake audio capture (`scripts/lib/make_quality_clip.py`: voiced syllables, log sine sweeps, silence gaps, about 39.5 s, looped by Chrome).
Each side taps its decoded remote track to 48 kHz PCM with an AudioWorklet and samples `getStats` every 500 ms.
Impairment is `tc netem` run in a sidecar that shares the LiveKit container's network namespace (`scripts/lib/e2e_netem.py`), so it needs no host root and shapes what the SFU sends to both listeners.
The ICE pair was UDP host-to-host in every run, so loss is real RTP loss and not hidden by TCP.
The browser's own echo cancellation, AGC and noise suppression are switched off for the senders, so only the call is judged.
`scripts/lib/voice_quality.py` aligns each recording to its clip, tracking the delay every 2 s, and reports six anomaly classes plus a similarity score.
`scripts/lib/test_voice_quality.py` checks every detector on synthetic signals with injected defects.

Environment knobs: `E2E_VQ_PROFILES` (comma list), `E2E_VQ_SECONDS` (per profile, per side), `E2E_VQ_VARIANT` (an Opus or sender setting, see `VARIANTS`), `E2E_VQ_OUT`.
`scripts/lib/voice_quality_table.py <dir>` prints the tables below from the saved `results.json`.

## Anomaly classes

- dropout: the reference has signal and the received level is 20 dB or more down for 30 ms or longer.
- click: a sample-step or second-difference spike eight times its neighbours, over 0.03, and four times anything the reference has there.
- static: noise-like spectrum (flatness above 0.25 and 0.15 above the reference) for 30 ms or longer.
- tone: a narrowband peak not in the reference, tracked for 0.3 s or longer.
- clipping: three or more consecutive samples at full scale.
- level_burst: the received level is 4 dB or more above the reference for 30 ms or longer (added after the first run showed an overshoot no other class describes).
- timing: drift and step changes of the tracked delay.

## Phase 2: findings per network profile

Baseline publish settings (dtx on, FEC on, 48 kbps cap), 240 s of two-way audio per profile, both directions summed.
Netem arguments: loss2 `loss 2%`, loss5-jitter30 `delay 20ms 30ms loss 5%`, burst `loss gemodel 1% 10% 70% 0.1%`, delay150-jitter50 `delay 150ms 50ms`.

| profile | min similarity | dropout | click | static | tone | clipping | level_burst | concealed samples | concealment events | packets lost | jitter buffer ms | kbps |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| burst | 0.963 | 75 | 1 | 0 | 0 | 7 | 107 | 447229 | 316 | 5 | 73 | 32.6 |
| clean | 0.979 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 32 | 32.6 |
| delay150-jitter50 | 0.979 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 153 | 32.5 |
| loss2 | 0.978 | 0 | 0 | 0 | 0 | 1 | 4 | 7400 | 12 | 0 | 51 | 32.5 |
| loss5-jitter30 | 0.973 | 21 | 2 | 0 | 0 | 2 | 42 | 213565 | 284 | 1 | 126 | 32.6 |

Reading the table:

- Clean and 150 ms delay with 50 ms jitter are indistinguishable from each other apart from the jitter buffer, which grows from 32 ms to about 150 ms to absorb the delay variation.
- Packet loss shows as concealment, not as lost packets: `packetsLost` stays near zero while hundreds of concealment events fire, so the SFU's NACK retransmits appear to refill the count after the decoder has already concealed.
  Use `concealmentEvents` and `concealedSamples` as the loss signal.
- In speech, loss costs short dropouts (50 to 190 ms, heard at 40 to 80 dB below the reference) and short overshoots (50 to 260 ms, up to +14 dB) where concealment is louder than the word it replaced.
- Neither is noise-like: the static detector found nothing in any profile, and the tone detector found no foreign tone.
- Delay drift of the tracked playout is up to 70 ms over 240 s, with steps of 5 to 25 ms in the lossy profiles; those are the jitter buffer accelerating and decelerating (`removedSamplesForAcceleration` up to 124k samples on the burst profile).

### Does anything match "a solid static note for about a second"?

No condition produced static or a foreign tone, in any profile, in 20 minutes of two-way audio.
The closest artefact is a level burst of +7 dB with full-scale clipping, 0.26 to 0.52 s long, that always lands at the same place in the clip: a descending pure-tone sweep at about 27 s, near 1.3 kHz.
It appeared under loss (loss2, loss5-jitter30, burst) and in short clean runs, and not in a 240 s clean run, so it is intermittent.
It is not a network effect: a libopus encode and decode of the clip with no network at all reproduces it at 16 to 64 kbps and not at 96 or 128 kbps.
A steady sine at any frequency or level does not trigger it, and neither does the speech-like content.
So a swept or gliding tone (whistling, game or music audio) at the 48 kbps ceiling can come out as a louder clipped note for a third of a second.
That is a plausible source of the report, but this harness has not seen it with speech.

# Voice idle bandwidth and the burst worst case (audit A11 and A8)

Written 2026-11-02 on `v122/a11-a8-idle-bandwidth`, base `v121/integration` (ef3e95df5), client 0.120.0, LiveKit server v1.10.1 in docker.
Raw JSON: `~/.slimm-scratch/tmp/idle/` (one folder per run).

## A11: what the desktop client sends while silent

`E2E_ONLY="voice idle bandwidth" scripts/e2e.sh` (`scripts/lib/e2e_voice_idle_bandwidth.py`) launches the real Linux client once per condition and reads the browser listener's inbound-rtp counters for that one track over a 59.5 s steady window, after a 12 s warmup.
The microphone plays one of two looped clips: seeded room noise at -66 dBFS RMS, or gapped piper speech.
Payload is the inbound `bytesReceived`; wire adds 50 bytes per packet (RTP 12, UDP 8, IPv4 20, SRTP tag 10).
Publish settings are the shipped ones: RED on, 48 kbps cap, clean network, one run per cell.

### DTX off (shipped), clean build of this commit

| suppression | condition | gate open share | payload B/s | packets/s | wire kbps |
|---|---|---|---|---|---|
| standard | silent, gate closed | 0.00 | 5754 | 50.0 | 66.0 |
| standard | silent, gate open | 0.97 | 11023 | 50.0 | 108.2 |
| standard | speaking | 0.53 | 8954 | 50.0 | 91.6 |
| strong | silent, gate closed | 0.00 | 5754 | 50.0 | 66.0 |
| strong | silent, gate open | 0.00 | 5748 | 50.0 | 66.0 |
| strong | speaking | 0.47 | 8746 | 50.0 | 90.0 |

- The earlier standard rows came from an older bundle (wt-v121-int); the strong rows are from a fresh build of this commit, because that bundle's rnnoise never ran in the strong arm.
- Strong removes the room noise entirely, so "gate open" is closed in practice and costs the same as a closed gate.
- A closed gate is not cheap with DTX off: digital silence still costs 46 kbps of payload, 66 kbps on the wire.
  `voice-input-gate.md` quoted 8 to 112 B/s, which was true only with DTX on.
- The audit's "VBR silence is a few bytes" lens doubt does not hold here: RED plus the 48 kbps cap keeps the stream near constant rate.

### DTX on (one flag flipped in `microphonePublishOptions`, same everything else)

| suppression | condition | payload B/s | packets/s | wire kbps | change in wire |
|---|---|---|---|---|---|
| standard | silent, gate closed | 139 | 4.8 | 3.0 | -63 kbps |
| standard | silent, gate open | 9000 | 49.2 | 91.7 | -16 kbps |
| standard | speaking | 6500 | 30.0 | 64.0 | -28 kbps |
| strong | silent, gate closed | 138 | 4.8 | 3.0 | -63 kbps |
| strong | silent, gate open | 138 | 4.8 | 3.0 | -63 kbps |
| strong | speaking | 6257 | 29.7 | 61.9 | -28 kbps |

The saving is large: a muted-by-gate or Strong-silenced microphone drops from 66 to 3 kbps, and speech with pauses from about 90 to about 63 kbps.

## DTX stays off: it brings back the artifacts it was removed for

Two checks the audit names, run with the same two builds.

Gliding-tone / synthetic clip, web path, clean network, 60 s (`E2E_VQ_CLIPS=synthetic E2E_VQ_VARIANT=dtx-off|dtx-on`):

| variant | dropout | click | clipping | level_burst | ViSQOL | kbps |
|---|---|---|---|---|---|---|
| dtx-off | 1 | 0 | 0 | 1 | 4.24 | 67.3 |
| dtx-on | 0 | 2 | 3 | 5 | 4.14 | 60.5 |

This reproduces the clipping and level bursts that moved DTX off in `voice-bursts.md`.

Word onsets on the desktop client (`voice desktop`, Strong or Standard with the gate on, 10 onsets per cell, one run):

| arm | profile | DTX off mean / worst lost ms | DTX on mean / worst lost ms |
|---|---|---|---|
| strong | clean | 15 / 30 | 17 / 30 |
| strong | burst | 11 / 20 | 24 / 80 |
| standard | clean | 11 / 20 | 5 / 10 |
| standard | burst | 13 / 30 | 15 / 50 |

Clean is a wash.
Under burst loss DTX on lost more of the word start in both arms, worst case 80 ms against 20 ms for Strong.
Ten onsets per cell is thin, so the onset result is a warning and not a proof; the tone result stands on its own.

Decision: DTX stays off, no code change.
If bandwidth for silent microphones matters later, the cheaper route is to stop sending while the gate is closed, not to change the codec mode for everyone.

## A8: the burst worst case still holds

Web quality harness, profile `burst` (`loss gemodel 1% 10% 70% 0.1%`), speech clip, 90 s per side, shipped publish settings:

| profile | ViSQOL | dropout | level_burst | static | concealment events | packets lost | kbps |
|---|---|---|---|---|---|---|---|
| burst | 3.89 | 12 | 13 | 0 | 154 | 537 | 78.7 |
| clean | 4.40 | 0 | 0 | 0 | 0 | 0 | 84.2 |

`voice-bursts.md` recorded ViSQOL 3.91, 14 dropouts, 14 level bursts and 1 static for the same profile with RED.
The numbers hold within run noise, so there is no regression and no code changed for A8.

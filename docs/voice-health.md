# Voice health

The client reads `getStats` on every remote voice and on our own published track about every 5 seconds while a call is up.
`AudioGlitchWatch` is the one sampler, and `VoiceHealth` (in `client/packages/rtc`) turns its readings into per-person quality, a log line and a summary.
The targets come from `docs/research/voice-experience-plan.md`, section (b).

## What is tracked

For each remote voice: concealed samples over samples received, concealment events, jitter, mean jitter buffer, packet loss, round trip and audio level.
The mean jitter buffer is the change in `jitterBufferDelay` over the change in `jitterBufferEmittedCount`.
For our own track: packets and bytes sent, the capture level from the media source, and the round trip and loss the far end reports.
Each reading is turned into an interval, the change since the previous reading, so a long clean stretch cannot hide a recent burst.
A muted remote is skipped, because a sender that is not sending would read as concealment.

## Thresholds

`kPoorConcealmentShare` is 5%, the point where concealment is heard as static.
`kRecoveredConcealmentShare` is 3%, the plan's ceiling at 5% loss with 30 ms jitter.
`kPoorJitterBufferMs` is 160 ms, the plan's ceiling at 50 ms jitter, and `kRecoveredJitterBufferMs` is 120 ms.
`kPoorRttMs` is 400 ms, the ITU-T G.114 planning ceiling, and `kRecoveredRttMs` is 300 ms.
`kPoorSendLossShare` is 5% and `kRecoveredSendLossShare` is 3%, for loss on our own audio as the far end reports it.
`kPoorSustain` is 5 seconds: a stream must stay bad that long before the hint shows.
`kRecoverSustain` is 10 seconds: it must stay clearly good that long before the hint goes.
An interval between the poor and recovered values changes nothing, which is what stops the hint flickering.

## Where it shows

Our own bad connection shows as a warning banner in the call stage, under the header.
It is a status the person did not ask for, so it pushes content down and never overlays it (rule 6 in `docs/design/desktop-vs-mobile.md`), and nothing shows while all is well.
On someone else's tile a quiet warning glyph appears in the top-left corner while their audio is poor.
A remote flag cannot say whose connection is at fault, so the glyph says only that the connection is unstable.
Tapping the glyph opens that sentence on the tile, because a hover tooltip never reaches a finger and must not be the only carrier.
The glyph is a per-person marker on that person's tile, so rule 6 does not apply to it.
The tile and the banner both carry a screen reader label.

The log gets one `[voice-health]` line about every 60 seconds, with each person's last minute of concealment, events, jitter, buffer, loss, level and round trip, but only when someone's minute reached a recovered threshold (3% concealment or send loss, a 120 ms buffer or a 300 ms round trip).
A healthy minute goes only to the call diagnostics panel, which shows the latest one, so a long clean call no longer fills the 200-entry debug log and pushes out what went wrong.
A transport reconnect is two lines: one when it starts and one when it ends, which carries its retry count and any escalation.
When the call ends it gets a summary: p50 and p95 of concealment, jitter buffer, jitter, round trip and loss, for everyone pooled and for each person.
A last line counts the transport blips, the times LiveKit's own resume or restart ran, with their total and longest duration; it is absent when the transport held.
Sampling pauses and the ping readout clears while one runs.

The jitter buffer's other work is logged when the platform reports it: late packets discarded, playout sped up (accel) or slowed down (decel), and concealed samples that were silence.
The summary pools them for everyone, with zeros shown, and lists a person only when theirs is above zero.
The minute line does the same per person.
A person's screen-share audio is sampled every fourth read under its own `Name (share)` entry and never flags a poor connection.
Our own line adds `erl` and `erle`, the echo canceller's return loss and its enhancement in dB, only when the platform reports them.
The first call also logs the raw media-source stats entry at debug level, to show which of those fields a platform has.
There is no "use headphones" hint: echo return loss reads near zero with headphones and is capped low, so no threshold on it would be right.

Settings, Troubleshooting, "Last call audio" shows the pooled summary of the last call that ended in this session.
It is kept in memory only, so it is empty after a restart; the log line is the durable record.

## Uplink test

An admin can measure what the server host can send, from Voice and screen share in Space settings.
`POST /space/uplink-test` uploads about 40 MB of zeros to `SLIMM_UPLINK_TEST_URL`, which defaults to `https://speed.cloudflare.com/__up`.
The upload stops after 20 seconds, and a slow link is then rated on the bytes the sender had taken by that point.
It needs MANAGE_SERVER, is recorded in the audit log as `space.uplink_test`, and sits behind the write rate limit.
It is refused with 409 while any voice session is open, because the upload would hurt the call, and with 429 within a minute of the last result.
A second test while one runs is refused with 409.
The last 10 results are kept in `uplink_tests`, and `GET /space/uplink-test` returns them newest first.
The page shows the last result as "Measured <date>, <n> Mbit/s", a suggested share ceiling, and how many viewers each tier can serve.
Only 70% of the measured rate counts as usable, which leaves room for call audio and overhead.
The server sends one copy of a share to every viewer, so a share watched by 4 people costs 4 times its bitrate, and the counts cover every viewer of every share.
The suggested ceiling is the tallest resolution at 30 fps that serves 4 viewers at once, never below 720p.
Bitrates come from `ScreenShareQuality.bitrateTable`, and simulcast layers are not counted.
The suggestion is advice only; the ceiling itself is still set under Screen share quality.

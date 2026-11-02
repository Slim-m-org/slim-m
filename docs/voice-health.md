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

A quiet warning glyph appears in the top-left corner of a person's call tile while their audio is poor, and on our own tile when our connection is.
It follows the status rule (rule 6 in `docs/design/desktop-vs-mobile.md`): it is not asked for, it does not overlay content, and nothing shows while all is well.
The glyph has a tooltip and a screen reader label.

The log gets one `[voice-health]` line about every 60 seconds, with each person's last minute of concealment, events, jitter, buffer, loss, level and round trip.
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

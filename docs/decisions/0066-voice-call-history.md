# 0066 - A voice channel's call history

Status: accepted, 2026-10-13.

## The problem

An empty voice channel is the normal state of a voice channel, and until now it showed a centred card with the last call's length, two names and a "left early" verdict, built on the client from its own session.
The owner's design (`curVrec/13-after-call`) asks for the call's own record instead: who was in when, who shared, what landed on the canvas, and the calls before it, "built only from events the server already has, with nothing recorded".

## What is kept

One table, `voice_call_events`, written from the LiveKit webhook the server already verifies (decision 0032): who joined, left, started or stopped sharing a screen in which channel, stamped when the webhook arrived.
Nothing else: no audio, no transcript, no speaking activity.

Calls are not stored; they are worked out when read.
A call starts when a channel's room goes from nobody to somebody and ends when it is empty again.
A call's canvas moments (an image pasted, strokes drawn) are not copied either; they are read from the canvas objects that already carry their author and time, inside the call's span.
Rows older than 30 days are swept, and the response states that retention so the client can say it on the pane.

A deployment without the webhook configured keeps no history and the pane falls back to its join bar alone.

## Who sees what

The route needs `VIEW_CHANNEL`.
Someone whose presence is hidden is left out of every call they were in for every viewer but themselves, exactly as the live roster already drops them, judged by their visibility at read time.

## Why events, not call rows

The webhook handler is synchronous and writes in spawned tasks, which can land out of order, and a server restart forgets who it was tracking, so the leaves that follow it are never seen as transitions.
Stamping each event when it arrives and segmenting at read time makes write order irrelevant.
At read time, anyone still counted in a call who is not in LiveKit's own participant list is treated as gone at the call's last event, which closes a call a restart left open.
The hub's broadcast channels were not used for this either: they drop a subscriber that lags, which suits live fan-out and does not suit a record.

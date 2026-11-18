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

A deployment without the webhook configured keeps no history and the pane shows its empty state (see the 2026-11-18 amendment).

## Who sees what

The route needs `VIEW_CHANNEL`.
Someone whose presence is hidden is left out of every call they were in for every viewer but themselves, exactly as the live roster already drops them, judged by their visibility at read time.

## Why events, not call rows

The webhook handler is synchronous and writes in spawned tasks, which can land out of order, and a server restart forgets who it was tracking, so the leaves that follow it are never seen as transitions.
Stamping each event when it arrives and segmenting at read time makes write order irrelevant.
At read time, anyone still counted in a call who is not in LiveKit's own participant list is treated as gone at the call's last event, which closes a call a restart left open.
The hub's broadcast channels were not used for this either: they drop a subscriber that lags, which suits live fan-out and does not suit a record.

## Amended 2026-11-10: calls in progress and drop-ins

The owner reported that the pane showed nothing about a call unless you were the last to leave, and that the history filled with "0m" rows.
The pane only showed finished calls, so anyone leaving a call that carried on saw the call before it.
It now shows a call still going at the top, labelled "This call", running up to now; finished calls follow below as before.
The "0m" rows were real: someone joined an empty channel and left within seconds.
A finished call shorter than a minute is no longer listed; a call still going always is.

## Amended 2026-11-18: the empty state

The owner said the empty voice channel view "looks bad": with nothing to look back on, the join bar sat alone at the top of a blank pane.
A channel with no calls to show (no webhook, a server too old, a failed load, or no calls yet) now gets a centred empty state instead: the channel's name, who is in it now, who can join, and the ways to join.
Join muted stays the primary action, as design 13 has it, with a plain Join beside it as the secondary one; a channel that joins muted offers only Join muted, and Try again repeats whichever join failed.
The empty state also stands in while the history loads, so Join is never held back by the request, and the history of the last few voice channels visited is kept, so coming back shows it at once and refetches behind it.

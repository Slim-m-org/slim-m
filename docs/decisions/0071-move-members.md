# 0071 - Moving members between voice channels

Status: accepted; built
Date: 2026-10-18

## The ask

The owner: "backlog being able to move people from voice channel to voice channel".
Moderators could only disconnect someone from a call, which leaves them to find their own way back.

## Decision

A new permission, `MOVE_MEMBERS` (bit 19), rather than reusing `KICK_MEMBERS`.

- `KICK_MEMBERS` is an elevated bit that also times people out and renames them. A role that should shuffle people between rooms should not also get to silence them.
- The bit is per channel, like `KICK_MEMBERS` on a voice eviction. A mover needs it, and `VIEW_CHANNEL`, in both the source and the destination, so an overwrite can keep a room off limits.
- The person being moved needs `VIEW_CHANNEL` and `CONNECT` in the destination. Nobody can be moved somewhere they could not have joined themselves, and a locked room still refuses someone who is not its owner or a channel manager.
- A destination at its user limit refuses the move, even for a channel manager. A move is not a way to overfill a room.
- Bots may hold the bit like any other permission, administrator included.
- No escalation guard. A move removes nothing the person cannot get back by joining the first channel again.

## Behaviour

`POST /channels/{id}/voice/participants/{user}/move` with `{to_channel_id}`. The person must be in the source call and the destination must be a voice channel in the space.

The server tells the moved account over the websocket (`voice.moved`, private to that account), then removes them from the source room through the room service. Clients join the destination by the ordinary token route, so the destination's lock and limit apply once more at join time.

Each move is written to the moderation audit log (`voice_move`), in the same history as removals and timeouts.

## Not decided here

- Moving several people at once.

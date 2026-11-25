<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0139 - Canvas channels, and the canvas as a setting on voice channels

Status: accepted
Date: 2026-11-25
Extends: 0017, 0073, 0085, 0127, 0137; amends 0047

## The ask

Nick, 2026-11-24, after he used a voice channel's canvas for modpack planning and felt he had claimed the call for his work.
The server half of this record is built; the client, presence and export halves follow it and are described here so the whole decision reads in one place.

- "now i have sortve claimed this voice call for my work instead of maybe just creating a canvas object?(text|voice|canvas?) and when we create voice, canvas is an optional setting to togggle? then we reduce bloat on calls that people think wont need canvas functionality and such"
- "I am a designer and im working on something, so i create a canvas labeled "new-designs-MVP" and when i create the channel I select canvas, then while I'm working on the design I can see when someone clicks on my canvas and is viewing it with me, if they have questions there should be some way to communicate verbally or through text I think, but its not primary, so perhaps we can have a toggle for canvas channels on creation to have an optional voice call, im looking for ux/ui sortve like figma"
- "under an export canvas area we can choose export to canvas channel"

## Decision

A channel has one of four kinds, and two predicates answer every question about its surfaces.

| kind | board | call | chat |
|---|---|---|---|
| `text` | never | never | primary |
| `voice` | when `canvas_enabled` | always | beside the call |
| `canvas` | always | when `voice_enabled` | secondary |
| `dm` | always | always | primary |

A thread of any kind has none of these.

- `kind` stays a free string end to end.
  Every shipped client, bot and module already reads an unknown kind as text, so no enum is added on either side.
- The server stores two columns, `channels.canvas_enabled` (read for voice only) and `channels.voice_enabled` (read for canvas only).
- `Channel::canvas_open()` answers "has a board now" and `Channel::hosts_call()` answers "has a call".
  No call site compares kind strings for these questions any more.
  A DM keeps its own explicit arm where DMs are accepted.
- `CANVAS_OPEN_SQL` is the same answer as a SQL fragment, for the two queries that must filter by it.
  A test pins it to `canvas_open()` over every kind, flag and thread combination.
- `Channel` and `RolePreviewChannel` carry two computed booleans, `canvas_enabled` and `voice_enabled`, identical for every reader.
  They are answers, not the stored columns, so a reader needs no kind lookup and the live path never masks them per reader.
- `TEXT_CHANNEL_KIND`, `VOICE_CHANNEL_KIND` and `CANVAS_CHANNEL_KIND` join `DM_CHANNEL_KIND`.

## The voice canvas toggle

- Create: `canvas_enabled` on a voice channel, absent means on.
  An older app, a bot or a script that never heard of the field keeps today's channel with the board its own UI already offers.
  The app's create sheet always sends the field, off unless the creator turns it on, which is how new voice channels default off in the product.
  `true` on any other kind is a 400.
- Update: `canvas_enabled` on a voice channel, a lobby's rooms included, and `voice_enabled` on a canvas channel.
  Either value on the wrong kind is a 400, whatever it is.
  Both count as something to update.
- Off hides the board and deletes nothing.
  Objects, props, attachments, locks, scenes and slots stay, the gate hides them, and turning it on brings everything back.
- `discard_canvas: true` on an update removes everything on a voice channel's hidden board, locked objects included.
  It needs `MANAGE_CANVAS` in the channel as well as the manage bar, and it is refused on an open board.
  It runs the clear inside the update's own write transaction, with the channel's latest seq read there, so no client needs a fence it cannot read from a board it is refused.
  It takes locked objects because locks guard live work against an accidental clear, a hidden board has no live work, and the action is explicit, confirmed and audited.
  The clear writes the usual audit rows and edge cascades, and `Cleared` is published after the commit.
- A lobby's rooms copy the lobby's `canvas_enabled` when they are made.
- Migration 0222 backfills: a voice channel with a live object on its board keeps its canvas on, and every other voice channel is turned off.
  A live object is one that is not erased, because an erased object is restorable but the board looks empty, and media slots are a call's tile arrangement, not content.
  Temporary rooms follow the same rule.
- In plain words, for the release notes: voice canvases are now a setting, and empty ones were turned off.
  A voice channel whose canvas was empty loses its Open canvas button, and the setting brings it back.

## The closed-surface gate

- The three board helpers, `canvas_read_access`, `canvas_access` and `ensure_may_draw`, refuse a closed board in the order view, surface, `USE_CANVAS`.
  A new board route that calls the usual helper is gated by default.
- A closed board answers 403 with `{"error": "the canvas is off in this channel", "code": "canvas_off"}`.
  It is a 403 and not a 409 on purpose.
  A shipped client maps a 403 on its board read to "The canvas is not available in this channel." and stops (`canvas_engine_reads.dart:51-52`), while any other status falls into a branch that retries forever (`canvas_engine_reads.dart:56-62`).
  The surface check runs after the view check, so a channel the caller cannot see still answers the plain 403 and is never told apart from a closed one.
- Screen stamps (0121) and screen annotations (0096) share the canvas bits but are not board routes.
  They move off the board helpers first, to `ensure_may_mark_screen` and `Frame::ScreenInk`, so they keep working in every voice channel whose board is off.
  They still refuse a member without `USE_CANVAS` and a timed-out one.
- WebSocket frames: `relay_grant` checks the surface for pointer and ink frames.
  The answer is cached on the same `PermissionCache` entry as the permissions and dropped by the same epoch, so a pointer still costs no query once cached and a toggle reaches an open socket without a reconnect.
- The LiveKit token masks `USE_CANVAS` when the board is closed, so the data grant follows it.
- A hidden board runs no module hosts: the tile refresh sweep joins through `CANVAS_OPEN_SQL`.
- A hidden board's images are not fetchable on its account: `channels_referencing_attachment` counts a board reference only on an open board, and a message reference counts as before.
- Call history reports no canvas activity and `canvas_object_count: 0` for a closed board.
- Text channels and threads are closed too.
  The server used to accept canvas writes there although no client offers it, and the original owner rule was that a text channel has no canvas.
  Live object counts per kind on prod and on slim-beta are taken before this deploys, and a non-zero count for text goes back to the owner.

## Calls in canvas channels

- `hosts_call()` replaces every voice-kind check: the token and heartbeat, move, transcription, call audio, notify preferences, join notices (0107), bot UI, watch sessions and module call audio.
- Eviction on kick, ban and timeout covers `voice` and `canvas` whatever the toggle says, so a member is removed even from a call a racing toggle-off is still ending.
- Turning `voice_enabled` off ends the room with the same `end_voice_room` the channel delete uses, after the row commits.
- A canvas channel is always a `channel` room for modules (0131), whatever its call toggle, so a room never changes kind under a live module room.
  Input stays gated on `SEND_MESSAGES`.
- A canvas channel's chat notifies like a voice channel's chat: mentions only by default, raisable per channel.
- Join notices follow voice's opt-in rule: nobody hears of a canvas call who did not ask.

## Viewer presence (built in the presence lane)

- A registry of who has a board open, fed by `canvas.watch` and flushed every 500 ms, publishes `canvas.viewer.changed` only when a user's shown state changes.
- `GET /presence/canvas-viewers` is one batched snapshot of every open board the caller can view, read once per connect.
- Hidden members are not listed.
  Visibility is decided when it changes, not at delivery, so a Hidden user leaves every list at once and a Hidden user's arrivals publish nothing.
- Shipped clients appear as viewers for free, because every client from 0.120.0 declares `canvas.watch`.
- Viewers show on canvas channels and voice canvases alike.

## Export (built in the export lane)

- `POST /channels/{channel_id}/canvas/export` copies a board into a new canvas channel in one transaction, with an option to clear the original in the same transaction.
- The new channel keeps exactly the source's audience, following 0064.
- A record keyed by the new channel's id makes a retry replay the first outcome and never clear a source it did not copy.
- Edges are remapped to the copies, their ends are written last by the code a placement uses, and blocked authorship is carried over.
- A ceiling on live objects, taken from a measurement, bounds the writer lock, and one export runs per source at a time.

## Compatibility

- A shipped client sees a canvas channel as a text channel with chat only, and cannot reach its call.
- A voice channel with its canvas off still shows Open canvas in a shipped client, which gets the 403 and its not-available message, with drawing blocked and no retry.
- There is no per-client filtering and no minimum client version.
  Filtering needs per-device identity and would hide mentions, and the floor of 0025 is reserved for data loss.
- A new client on an older server finds `/version.canvas_channels` absent and falls back to the old rule: voice and DM have a board and a call, text has neither.
- `/version.canvas_channels` is a boolean, not a capability, because a kind is not a route.
  The two capabilities `canvas_viewers` and `canvas_export` are read off the router like the others, so each appears the day its route does.
- Bots read `kind` as any string and are unaffected.
  The slim-bots changes ship before this server does.

## Alternatives rejected

- A `surface` flag on text and voice instead of a kind: the lowest risk, but the wrong model, and a callless canvas channel would be indistinguishable from text to every older reader.
- Filtering canvas channels from old clients, and a minimum-version floor.
- Masking `USE_CANVAS` in the permission evaluator: three copies of the permission code, and it blurs "no permission" with "off".
- Deleting a voice canvas when it is turned off.
- A non-atomic or asynchronous export, and a clear after the copy in a second transaction.
- A per-channel roster route read once per rail row.

## Consequences

- Boards are still absent from data exports, a gap that already existed.
- A hidden board still counts as stored data until it is discarded.
- Old clients show a dead Open canvas on voice channels whose canvas is off.
- An export larger than the ceiling has to be thinned first.

## References

0006, 0017, 0025, 0047, 0064, 0065, 0073, 0085, 0087, 0096, 0107, 0121, 0127, 0131, 0137, 0138.

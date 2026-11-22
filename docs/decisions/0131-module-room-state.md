<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0131 - Modules keep a small shared state per call or channel

Status: accepted; built
Date: 2026-11-22
Extends: 0090 (phase 4, surfaces), 0091 (phase 1 contracts), 0100 (add-on API levels)

## Why this exists

Phase 4 of decision 0090 puts games and other live things in a call.
Three surfaces are planned for it: a call scene slot, a canvas tile slot and a Dock panel slot.
Each needs the same thing underneath: one state that everyone in the room sees, changed one step at a time, that someone who joins late can read.

Before this, a module could keep state in three places, and none fits.
A shared scene keeps its `state` in a message, so it lives in a text channel's history and not in a call.
`kv.store` and `data.store` are private to the module, so nobody else sees a change until something asks.
The run `context` (v120) tells a module which call it runs for, but every member's command still runs on its own, with nothing stopping two moves from reading the same board.

This record fixes the contract the three surfaces build on.
It draws nothing: the surfaces decide how a state looks.

## The contract

A room is one module's state in one channel: a voice channel, where the room is the call, or a text channel.
A direct message is never a room.

- **Capability.** A module declares `room.state` in `capabilities` with `"addon_api": 6`, and an admin approves it at install like any host capability.
  It is not a host call: like `events`, it is a permission to be run.
  The consent line says the module can keep a small state, such as a game board, that everyone in a call or channel sees.
  An approval carries across a new build, as `kv.store` does, because the state is shown only to people who can already see the room, and every install drops the module's rooms anyway.
- **Input.** A participant sends `POST /channels/{channel_id}/module-rooms/{module_id}/inputs` with `{"input": "<text>"}`.
  The host runs the module with `command: "@room"` and `input` set to `room/1`:
  `{"$slim":"room/1","room":{"channel_id","kind":"voice"|"channel"},"seq":<n>,"state":<the state held, or null>,"input":"<the text>"}`.
  The run's `caller.id` is the sender's per-module id (decision 0038), so a module can seat players without learning who they are.
  The run's `context` names the room as `voice_channel_id` for a call or `channel_id` for a text channel.
- **Answer.** The module's `output` is one of three:
  `{"$slim":"room/1","state":<any JSON>}` stores the next state;
  `{"$slim":"room/1","reject":"<why>"}` refuses the input, keeps the state and tells only the sender (at most 200 characters);
  `{"$slim":"room/1","end":true}` ends the room.
  Anything else is a failure.
- **Fan-out.** Each stored state goes to everyone who can view the channel as a `module.room` frame, `{channel_id, module_id, seq, state}`, and as `state: null` with `ended` when the room ends.
- **Catch-up.** `GET /channels/{channel_id}/module-rooms` lists every module's state in the room, for anyone with `VIEW_CHANNEL`.
  A late joiner reads it once; after that the frames keep it current.

Fixtures for the input and the three answers are in `docs/modules/room-fixtures/`, and a host unit test fails if the host stops sending exactly the input fixture.

## Ordering and the one writer

- Inputs to one room are applied one at a time, in the order the host received them.
  A room holds a fair lock for the whole of one input, so the module is the only writer and never sees two inputs at once.
- `seq` is the room's count of stored states, from 1.
  The module is sent the `seq` of the state it is given, and a stored answer is `seq + 1`.
  A refusal or a failure does not move it.
- A client applies a frame only when its `seq` is above the one it holds, and replaces everything from the list route after a reconnect.
- Different rooms, and different modules, run in parallel.

## Who may do what

- Reading: `VIEW_CHANNEL`, both on the route and on the socket.
  The socket authorizes every frame per subscriber with the same view check every channel event already passes, so nobody who cannot see the channel gets a byte of its state.
  The state is the same for every viewer; nothing is masked per reader, so the live path costs no more than any other channel frame.
- Sending: `VIEW_CHANNEL`, plus being in the call for a voice room (the host's own heartbeat record, the check the run `context` already uses), or `SEND_MESSAGES` for a text room.
  Who may move in a game is the module's business: it refuses an input with `reject`.
- The state is visible to everyone in the room, so a module must not keep a secret in it, the same warning shared scenes carry.

## Caps

| What | Cap | Past it |
| --- | --- | --- |
| Input text | 1024 bytes | 400, the module is not run |
| State | 16 KiB, as the module wrote it | a failure; the state stays |
| Input rate | 8 at once, then 2 a second, per member per room, on top of the module run rate | 429 |
| Waiting inputs | 8 per room | 429 |
| Rooms | 64 per module | 409 |
| Idle | a room without an input for 24 hours is dropped | ended `idle` |

## Failure

A run that traps, times out, runs out of fuel, answers `ok:false`, answers outside `room/1` or answers a state over the cap leaves the state as it was.
The sender gets `applied: false` with `error`, and nobody else is told anything.
The failure counts toward the module's existing circuit breaker (decision 0091), exactly as a background run does: five in a row turn the module off, with the admin alert and audit row, and any success starts the count over.
A full run lane is the host's load and does not count, as everywhere else.
A refusal (`reject`) is a success.

A member can therefore trip the breaker of a buggy module by sending it inputs that make it fail.
That is accepted: the input rate caps how fast, a module that traps on input is broken for everyone anyway, and the alternative of never counting room runs would let a broken module fail forever unseen.

## Memory only

Rooms live in the server's memory and nowhere else.
A restart drops every room, and clients see an empty list when they reconnect.

Durable rooms were considered and declined for now.
A table (migration 0205 was reserved for it) would survive a restart, but it adds a write on every move, a sweep for rooms whose call ended while the server was down, and a migration that can never be taken back.
The acceptance (a game in a call, in step for everyone, readable by a late joiner) needs none of that.
A call itself does not survive a restart in any useful sense: people reconnect, and a turn-based game started again costs a minute.
A module that must keep something across restarts (a score, a saved game) writes it to its own `data.store`, which is durable and private, and can rebuild a room from it on the next input.
If a surface later needs rooms to survive a deploy, a table can be added under a new record without changing this contract.

## When a room ends

- The module answers `end`: `ended: "ended"`.
- The call finishes (LiveKit's `room_finished`): `call_ended`.
- The channel is deleted: `channel_removed`.
- The module is disabled, uninstalled, installed again or turned off by the breaker: `module_off`.
- Nobody sent an input for 24 hours: `idle`.
- The server restarts: nothing is sent; the list is empty afterwards.

An input waiting for a room that ends meanwhile starts a fresh room.

## What it never does

No route, frame or run here creates a message, fires a push or raises a notification.
A run gets the module's usual host calls for the sender, except `message.post`, which is refused as for any run that names no channel.

## Compatibility

- Additive only: two new routes, one new frame, one new capability, one new contract.
  A client that does not know `module.room` ignores it; an older module never declares `room.state` and is never run with `@room`.
- A deployment with no module approved for `room.state` keeps no room, sends no frame and answers an empty list.
- The add-on API is 6.
  A module that declares `addon_api_max` of 5 must be updated to run on a level 6 server, as at every level; no official module declares one.
- An older server answers 404 on both routes, which the client provider reads as no rooms.

## For the surfaces that build on it

A slot renders from the client provider `moduleRoomsProvider(channelId)` in `client/packages/app/lib/src/features/modules/providers/module_rooms.dart`.
It holds every module's room in that channel by module id, sends an input with `send(moduleId, input)`, and keeps the module's last refusal or failure for the sender in `notices`.
How a state becomes pixels (a `scene/1` the module derives from its state, or a tile type) is each slot's own decision record.
The call scene slot is decision [0133](0133-module-call-scene.md): a `state` answer may carry a `scene`, kept and sent with it.

## Where it lives

- Server: `http/module_rooms.rs` (routes), `module_rooms/contract.rs` (`room/1`), `registry.rs` (rooms in memory), `turn.rs` (one input), `lifecycle.rs` (ending and the idle sweep).
  `hub/event/module_room.rs` and `http/ws/frames.rs` carry the frame.
- Client: `client_module_rooms.dart` and `models_module_rooms.dart` in `api`, the `module.room` frame in `events_frames.dart`, and the provider above.
- Proof: the `noughts` module in slim-addons, noughts and crosses in a call.
  `tests/it_modules/module_rooms.rs` drives two players and a late joiner through the real router and socket with its build.

<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0132 - A module fills a scene on the call's stage, drawn from its room state

Status: accepted; built
Date: 2026-11-22
Extends: 0131 (room state), 0090 section 6 (slots), 0091 (slot/1), 0047 (the call dock and stage)

## The question

Decision 0131 gives a module one shared state per call and leaves how a state becomes pixels to each surface.
The call scene slot needs a picture of that state that everyone in the call sees the same way, and a way for a tap on it to become the room's next input.

## Where the scene comes from

The module draws it in the same answer that stores the state.
A `room/1` answer with `state` may carry `scene`, a `scene/1` object (the same vocabulary messages and the Dock already paint), at most 32 KiB.
The host keeps it next to the state, under the same `seq`, and sends it wherever the state goes: the input's answer, the `module.room` frame and the room list.

Declined:

- A derived run (the host runs `@scene` on each stored state). It doubles the runs per move, adds a second failure point between a stored state and its picture, and a scene that failed to draw would leave everyone on a stale board with a fresh `seq`.
- The client turning state into pixels. Room state is opaque by design (0131); the client would need per-module code, which 0090 section 6 rules out.
- A separate scene frame or route. A second sync path could deliver a scene and a state out of step.

So the module stays the room's only writer, one input makes one answer, and a scene can never be newer or older than its state.
Every participant paints the same scene for the same `seq`.
A scene is therefore the same for every viewer: it may say "X to move", never "your move".

A scene that is not an object tagged `scene/1`, is over the cap, or comes without a state is a failure under 0131's rules: the state stays and the failure counts toward the breaker.
A state answered with no scene is stored as before; the stage then says there is nothing to show yet.

## The slot

- A manifest declares `{"kind": "call.scene", "name": ..., "title": ...}` in `slots`, at most one per module, and only with the `room.state` capability.
- `GET /channels/{channel_id}/module-rooms` gains `call_scenes` for a voice channel: each enabled module with `room.state` approved and a `call.scene` slot, with the slot's title.
- Opening a scene whose room holds nothing sends the empty input; the module answers its opening state and scene.
- A tap or a control in the scene sends its action text as the room's input, unchanged. A scene's own `state`, `refresh_ms` and private flag mean nothing here: the room keeps the state.
- A refused move shows the module's reason under the board, in the scene's own inline error (never a SnackBar). A room that failed to open shows the module error state with a retry; a room that ended shows "Not running" with Start.

## On the stage

- The scene takes the place a share would (decision 0114's fit, 0047's "with a share" stage): the first and largest tile, with the participants beside or under it in the strip a share already uses. It never covers a participant and the stage still reserves the dock's measured height.
- Its tile's aspect is the scene's own, made taller by a third for the title and controls; the board is fitted inside, so a square board stays square at 390 and 1280.
- Layout follows width only (desktop-vs-mobile.md law 1). The header button that opens a scene is one button for one scene and a menu for several, anchored at pointer width and a sheet at touch width (surface rule 1).
- A scene somebody started shows for everyone in the call. Closing it hides it for that viewer only, until they open it again from the header.
- Only someone in the call sees the stage, and only they can send input (0131).

## Compatibility

- Additive within add-on level 6, which has not shipped: one optional answer field, one optional frame and list field, one list field, one slot kind.
- An older client ignores `scene` and `call_scenes`. An older server sends neither, and the header shows no button.
- A module that never draws a scene behaves exactly as under 0131.

## Where it lives

- Server: `http/module_rooms/contract.rs` (the `scene` answer), `registry.rs` (kept with the state), `http/module_rooms.rs` (`call_scenes`), `http/dock/manifest/platform.rs` (the slot).
- Client: `call_scene_stage.dart` and `call_scene_launcher.dart` in `features/modules/widgets`, `call_scene_choice.dart` in its providers, and the `scene` item in the voice stage's `stage_content.dart`.
- Proof: noughts 0.2.0 in slim-addons; `tests/it_modules/module_rooms_call_scene.rs` and `test/features/voice/call_scene_stage_test.dart`.

# Add-on API changelog

Every change to a contract a module depends on is listed here, newest first.
The policy behind the levels is decision [0100](../decisions/0100-module-safety-contracts.md).

## Level 7

- Adds connectors (decision [0090](../decisions/0090-modules-as-the-extension-surface.md), guide [connectors.md](connectors.md)): `"provider": "connector"` with `"addon_api": 7` and `"connector": {"permissions": [<core permission names>]}`. A connector has no artifact or runtime and declares none of a WASM module's sandbox; `settings` is the one shared section.
- A level 6 host refuses a connector manifest, since it has no artifact.
- `DockManifest` gains `provider` and `connector.permissions` (bits); a connector's `artifact` and `runtime` read as kind and backend `connector` with an empty path and sha256, so an older app still parses the listing.
- `POST /space/dock/modules/{id}/install` takes `approved_connector_permissions` and refuses a connector without it, so an app that cannot show the ask cannot install one. `InstalledDockModule` gains `provider`, `connector_permissions` and, in the install answer that created it, `connector_token`.
- New routes: `POST /space/dock/modules/{id}/connector-token` and `GET /connectors/me`.
- The run request's `caller` gains an optional `name`: the caller's display name as other members see it in that space (nickname, else display name, else username), a snapshot taken when the run started. It is sent on every run that has a caller, a host below level 7 never sends it, and it is left out when the account cannot be read.
- `message.post` content may carry `{{mention:<caller id>}}`: the host writes it as `@username` for the member whose `caller.id` (for this module) it names, so the normal mention rules apply. Only ids the host computes for this module are expanded; any other token, a member who cannot view the channel, and tokens past the tenth in a message stay literal. `@everyone`, `@here` and roles are not reachable through it.
- A one-shot timer (`run_after`) armed from a channel now runs against that channel: `context.channel_id` is that channel and `message.post` posts there as the module's principal under the usual view and send check. A timer whose channel was deleted is dropped without running. A timer with no channel and the daily `schedules` keep using the admin's schedule channel.
- Nothing is removed or changed in meaning. A module that declares `addon_api_max` of 6 must be updated to run on a level 7 server, as at every level.

## Level 6

- Adds the `room.state` capability (decision [0131](../decisions/0131-module-room-state.md)): a small shared state the host keeps per module in a call or a text channel. It needs `"addon_api": 6`.
- Adds the `room/1` contract: the host runs `@room` with the room, its `seq`, the state it holds and the participant's input, and the module answers a next `state`, a `reject` or `end`. Inputs to one room run one at a time in the order they arrive.
- Adds `GET /channels/{channel_id}/module-rooms`, `POST /channels/{channel_id}/module-rooms/{module_id}/inputs` and the `module.room` websocket frame.
- A failed, slow or malformed answer keeps the state and counts toward the module's circuit breaker. Rooms are memory only and end with the call, the channel, the module or a day without input.
- Adds the `panel` extension point (decision [0132](../decisions/0132-dock-panels.md)): `{ "kind": "panel", "name", "permission", "command", "description"? }`, at most 2 per module, with `"addon_api": 6`. A level 5 server refuses such a module at install instead of installing it without its panel.
- Adds `GET /modules/panels`, listing the panels the caller holds the permission for. A panel runs through the existing `POST /modules/{id}/commands/{command}`; there is no new run route and no new contract version.
- Nothing is removed or changed in meaning. A module that declares `addon_api_max` of 5 must be updated to run on a level 6 server, as at every level.
- Fixtures for the input and the answers are in `docs/modules/room-fixtures/`.
- Adds the `call.scene` slot (decision [0133](../decisions/0133-module-call-scene.md)), at most one per module and only with `room.state`: the call's stage paints the module's room scene.
- A `room/1` `state` answer may carry `scene`, a `scene/1` drawn from that state (at most 32 KiB). The host keeps it with the state and sends it in the input's answer, the `module.room` frame and the room list; a scene that is not tagged `scene/1` or is over the cap is a failure. `room.reply.scene.json` is its fixture.
- The room list gains `call_scenes` for a voice channel. A call's stage opens a scene with the empty input, and a tap or control sends its action text as the next input.
- Adds the `canvas-tile` extension point: `{ "kind": "canvas-tile", "name", "permission", "command", "description"? }`, with `"addon_api": 6`. A member who holds `permission` places it on a voice canvas from the canvas menu; it is a canvas object of kind `module` whose `props` are `{"module_id", "tile"}`, so it moves, resizes, restacks and is removed like any other object.
- The tile's frame is `command`'s scene, run with the same interactive scene protocol as an `app` surface: the host keeps the frame's `state`, a launch is an empty input, presses run as whoever pressed, a failed or private answer reaches only the presser, and `refresh_ms` redraws as the last presser. `context.channel_id` is the canvas's channel, and `context.voice_channel_id` is set when the presser is in that call.
- New routes: `GET /modules/canvas-tiles`, and `GET`/`POST /channels/{id}/canvas/objects/{id}/scene`. New frame: `canvas.tile.scene_changed`. An older client ignores both the frame and the `module` kind.

## Level 5 additions (no level bump, nothing to declare)

- A scene's `controls` may hold a dropdown, `{"label", "value", "options"}`, alongside button names; picking an option sends it as the action. This is read by the client (0.132 and later), so the server and the add-on level are unchanged, and an older client skips the entry. Its optional `replaces` lists buttons in the same row that the dropdown stands for: an older client shows them, a newer one leaves them out.
- `call.audio.started` gains `names`, an object of user id to display name (the username when there is none) for everyone in `included`.
- `call.audio.participant` gains `name`, the same for `user_id`; it is absent when the member cannot be read.
- Only people already in the consented set are named. A module must keep working without either field, as an older server sends neither.

## Level 5

- Adds six events in the `event/1` envelope, each needing a `subscriptions` entry and `"addon_api": 5`: `message.edited`, `voice.participant.joined`, `voice.participant.left`, `voice.screen_share.changed`, `member.roles.changed` and `poll.voted` (decision [0109](../decisions/0109-more-module-events.md)).
- `reaction.changed` gains `user_id` and `added` in `data`, and is now sent once for each reactor who moved rather than once for each emoji. Its `id` gains a trailing `:<user id>`.
- Nothing is removed or changed in meaning. `event/1` stays `event/1`: a module that reads only the fields it already knew is unaffected.
- A module that declares `addon_api_max` of 4 must be updated to run on a level 5 server, as at every level.
- Fixtures for the new events are in `docs/modules/event-fixtures/`.

## Level 4

- Adds the `call.audio` capability (decision [0105](../decisions/0105-module-call-audio.md)): a module hears a voice call as text, only in channels an admin chose and only while everyone in the call agrees.
- Adds the `call_audio` manifest block: `purpose` and `keeps` (20 to 240 characters each, shown word for word to everyone in a call) and an optional `permission`, one of the module's own, that a member needs to start a session. It is required with the capability, together with `"addon_api": 4`.
- Adds four events in the `event/1` envelope: `call.audio.started`, `call.audio.participant`, `call.audio.segment` and `call.audio.stopped`. They need no `subscriptions` entry.
- Adds no host call. A module only listens.
- Nothing is removed or changed in meaning. A module that declares `addon_api_max` of 3 must be updated to run on a level 4 server, as at every level.

## Level 3 additions (no level bump, nothing to declare)

- The run request gains an optional `context` object: `channel_id` (the channel a command ran in, a surface lives in, or a timer was set from) and `voice_channel_id` (only when the host confirmed the member is in that call).
- A shared scene may carry a top-level `refresh_ms` (2000 to 60000, clamped): the host runs the surface's command again with the action `refresh` and the held `state`, stores and broadcasts the result, and repeats while the module keeps asking. A chain ends half an hour after the last person pressed something.
- An answer with `ok: true` may carry `run_after`: `{ "command", "after_ms", "key"?, "input"?, "cancel"? }`. The host runs that command once, no sooner than 10 s later, as the module's own principal. It needs `schedule` approved, a command the manifest declares, at most 32 pending timers per module, and a new request for the same command and key replaces the old one.
- Modules can be exported to and installed from a package file; this changes no module contract.

## Level 3

- Adds interceptors (`message.pre_send`, `message.pre_edit`) and the deny-only permission check hook, each with the `interceptors` and `permission.hook` host capabilities.
- Adds the `interceptor/1` and `permission/1` contracts.
- Adds `addon_api_max` to the manifest: the newest level the module declares it works with.
- Adds `"hosts"` to a `secret` setting, and `"member": true` to a `text` data column.
- The `@event` input gains a `"$slim": "event/1"` field naming its contract version.
- Nothing is removed or changed in meaning.

## Level 2

- Private scenes (decision 0099).

## Level 1

- The module platform: events, `data.store`, `log.read`, settings, slots (decision 0091).
- `slot/1` and `event/1` are the first versions of those contracts.

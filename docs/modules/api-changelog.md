# Add-on API changelog

Every change to a contract a module depends on is listed here, newest first.
The policy behind the levels is decision [0100](../decisions/0100-module-safety-contracts.md).

## Level 5

- Adds six events in the `event/1` envelope, each needing a `subscriptions` entry and `"addon_api": 5`: `message.edited`, `voice.participant.joined`, `voice.participant.left`, `voice.screen_share.changed`, `member.roles.changed` and `poll.voted` (decision [0107](../decisions/0107-more-module-events.md)).
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

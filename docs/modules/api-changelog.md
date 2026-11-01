# Add-on API changelog

Every change to a contract a module depends on is listed here, newest first.
The policy behind the levels is decision [0100](../decisions/0100-module-safety-contracts.md).

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

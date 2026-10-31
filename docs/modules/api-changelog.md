# Add-on API changelog

Every change to a contract a module depends on is listed here, newest first.
The policy behind the levels is decision [0100](../decisions/0100-module-safety-contracts.md).

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

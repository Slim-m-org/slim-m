# Connectors

A connector is a module whose logic is an external program instead of a WASM artifact (decision [0090](../decisions/0090-modules-as-the-extension-surface.md)).
It is a bot with a manifest: the Dock installs it, the admin approves what its token may do, and its settings render in the app like any module's.
This page covers an admin-started connector: the admin runs the program themselves and gives it the token.
A host-run connector, started by the host in a sandbox, is decision [0134](../decisions/0134-connector-runtime-supervisor.md) and is not built yet.

## The manifest

```json
{
  "schema": 1,
  "id": "jellyfin",
  "name": "Jellyfin",
  "version": "0.1.0",
  "summary": "Posts what is playing on a Jellyfin server.",
  "provider": "connector",
  "addon_api": 7,
  "connector": {"permissions": ["view_channel", "send_messages"]},
  "settings": [
    {"key": "server_url", "type": "string", "label": "Server address"},
    {"key": "api_key", "type": "secret", "label": "API key"}
  ]
}
```

- `provider` is `"connector"`; leaving it out means a WASM module, as before.
- `addon_api` must be 7 or higher, so a level 6 host refuses the manifest instead of installing it as a module with no artifact.
- `connector.permissions` lists the core permissions the token asks for, by name.
  The names are `administrator`, `view_channel`, `send_messages`, `manage_messages`, `manage_channels`, `manage_roles`, `kick_members`, `ban_members`, `create_invite`, `add_reactions`, `attach_files`, `connect`, `speak`, `use_canvas`, `manage_canvas`, `manage_server`, `mention_everyone`, `run_code`, `view_moderation_history`, `move_members`, `view_transcripts` and `use_soundboard`.
- `settings` is the same schema a WASM module uses, and the app renders it the same way.
  A secret takes no `hosts`, since the host sends a connector the value itself.
- A connector declares no `artifact`, `runtime`, `capabilities`, `network`, `schedules`, `subscriptions`, `interceptors`, `permission_hooks`, `data`, `call_audio`, `extension_points`, `slots` or module `permissions`.
  Those describe a sandbox the host runs, and a manifest naming any of them is refused.
  A connector reaches events over the websocket and registers its commands and call controls as any bot does (`PUT /bots/commands`, `PUT /bots/ui`).

## Install

The Dock shows what the connector asks for, and the admin approves some or all of it.
The install answer carries `connector_token` once, for the admin to hand to the program.
It is never shown again; `POST /space/dock/modules/{id}/connector-token` replaces a lost one and closes the old token's sockets.

The host creates the connector's principal, a bot account with the shared Bots role and its own role granting what was approved.
The approval is also a ceiling: whatever roles the principal is given later, and whatever the Bots role or `@everyone` grant, the token can use only the approved bits.
That holds in channels, in direct messages, for module permissions (a connector holds none) and in websocket fan-out.
While the connector is disabled its ceiling is zero.
Updating the connector to a new version asks again, and a narrower approval takes effect at once.

Uninstall revokes the token, closes its sockets, removes every role and overwrite its principal held, and then removes the principal; its messages stay.

## Reading settings

The program reads itself with its token:

```text
GET /connectors/me
Authorization: Bearer slimbot_...

{"module_id": "jellyfin", "name": "Jellyfin", "version": "0.1.0", "permissions": 6,
 "settings": {"server_url": "http://jellyfin:8096", "api_key": "..."}}
```

Each declared setting appears with its stored value, else its default, else `null`.
Secret values are in plain text here and nowhere else: the admin's settings view shows only whether a secret is set, and no audit row or listing carries one.
Any other caller gets 403, and a disabled connector gets 409.
The answer is not pushed when an admin changes a setting, so a connector reads it again on its own schedule.
The slimbots library does this for a bot that declares a manifest (`slimbots.connector`).

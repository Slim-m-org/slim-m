# Connectors

A connector is a module whose logic is an external program instead of a WASM artifact (decision [0090](../decisions/0090-modules-as-the-extension-surface.md)).
It is a bot with a manifest: the Dock installs it, the admin approves what its token may do, and its settings render in the app like any module's.
This page covers an admin-started connector: the admin runs the program themselves and gives it the token.
A host-run connector, started by the host in a sandbox, is decision [0134](../decisions/0134-connector-runtime-supervisor.md) and has its own section below.

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
- `permissions` and `extension_points` of kind `command`, `slash-command` and `panel` are the same as a WASM module's (see [Commands and panels](#commands-and-panels)).
- A connector declares no `artifact`, `runtime`, `capabilities`, `network`, `schedules`, `subscriptions`, `interceptors`, `permission_hooks`, `data`, `call_audio` or `slots`, and no other extension point kind.
  Those describe a sandbox the host runs, or runs the host starts on its own, and a manifest naming any of them is refused.
  A connector reaches events over the websocket, and can still register message menu entries and call controls as any bot does (`PUT /bots/ui`).

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

## What a connector's token may call

A connector's token acts within the permissions the admin approved, and many routes check no permission because every member may use them.
A connector is not a member using the app, so its token is held to a table first:

- A disabled connector reaches `GET /connectors/me`, which answers 409, and nothing else.
- A person's own routes are never a connector's: account, sign-in, devices, push, notifications, favorites, saved messages, blocks, reports, invites, exports, diagnostics, presence and read states answer 403.
- Opening and listing DMs needs `send_messages`, uploads need `attach_files`, a channel's voice routes need `connect`, and directory reads (members, users, channels, categories, emoji, the soundboard, the Space's settings) need `view_channel`.
- `GET /me`, `POST /auth/ws-ticket`, `PUT /bots/commands` and `PUT /bots/ui` work with no approval, so a connector can open its socket and register its commands.
- The generic bot routes (`/bots/{id}/token`, `/revoke`, `/permissions`, `/prefix`) answer 404 for a connector's principal; its token belongs to the Dock.
The answer is not pushed when an admin changes a setting, so a connector reads it again when it needs to.
The slimbots library reads it at start for a bot run with `SLIMM_CONNECTOR=1` (`slimbots.connector`).

## Commands and panels

A connector declares its commands and panels in the manifest exactly as a WASM module does, and members find them in the same places: slash commands in the composer, panels in the Apps menu and the Dock panel.

```json
"permissions": [{"key": "use", "name": "See servers", "description": "Lists the game servers."}],
"extension_points": [
  {"kind": "command", "name": "servers", "permission": "use"},
  {"kind": "slash-command", "name": "servers", "permission": "use", "command": "servers"},
  {"kind": "panel", "name": "Servers", "permission": "use", "command": "servers"}
]
```

When a member runs one, the host checks install, enable and permission as for any module, then sends the run to the connector's own websocket connections:

```json
{"type": "connector.run", "run_id": "0190...", "module_id": "pelican", "deadline_ms": 6000,
 "request": {"command": "servers", "input": "", "caller": {"id": "<64 hex>", "name": "Ada"},
             "entropy": "...", "now_ms": 1700000000000, "settings": {...}, "context": {"channel_id": "..."}}}
```

`request` is the run request a WASM module reads, so `input` is `""` when a panel opens and `{"action", "state"}` when its scene is pressed.
`caller.id` is the same opaque per-module id, never the member's account id.
`context` names a channel only when the connector may view it, and `settings` carries no secret values (read those from `GET /connectors/me`).

The connector answers once, with its own token, in the WASM answer shape:

```text
POST /connectors/me/runs/0190...
{"ok": true, "output": "two servers up"}        or        {"ok": false, "error": "the panel is down"}
```

`output` is text or a `scene/1` document as text, at most 1 MiB in all.
The answer gets 204; 404 when no run with that id is waiting for this connector (it timed out or was answered), and 400 when it is not that shape, which the member also sees as a failed run.

- The host waits at most `deadline_ms` (6 seconds, what a WASM module that can fetch gets), then tells the member the connector did not answer.
- An offline connector is told nothing and the member reads "<name> is offline" at once.
- A connector holds at most 8 waiting runs, and one member at most 2 of them; past that a run is turned away at once as busy.
- A disabled or uninstalled connector is sent nothing; the member gets the same refusal as for a disabled module.
- A member's "post the output" (`post_output`) is refused unless the connector itself may view and send in that channel.
- Posted output reaches `@everyone` and `@here` only when both that member and the connector hold `mention_everyone`, so neither borrows the other's.
- The frame is lossy like a button click: a connector that reconnects does not get missed runs, and those members see the timeout.

The slimbots library does this for a bot run with `SLIMM_CONNECTOR=1`: `@bot.manifest_command("servers")` answers a command or a panel with text or a scene.

## Host-run connectors

A connector can ask the host to run its image instead (decision [0134](../decisions/0134-connector-runtime-supervisor.md)).
This needs the operator's connector supervisor ([docs/connectors/operating.md](../connectors/operating.md)); a server without one answers 501 to the install.

```json
"connector": {
  "permissions": ["view_channel", "send_messages"],
  "host_run": {
    "image": "ghcr.io/slim-m-org/jellyfin-connector@sha256:<64 hex>",
    "egress": [{"host": "jellyfin.lan", "port": 8096}],
    "egress_private": true,
    "volume": true,
    "limits": {"memory_mib": 128, "cpus": 0.5, "pids": 64, "volume_mib": 256}
  }
}
```

- `image` must be pinned by digest, with no tag, under a registry prefix the operator allows.
- `egress` lists the `host:port` pairs it asks to reach, at most 32; the admin approves some or all of them.
  `egress_private` asks for the Private network approval, which a LAN address needs.
- `volume` asks for a data volume at `/data`; `limits` fall back to the supervisor's defaults.
  `volume_mib` is the volume's ceiling (default 256): the supervisor measures it every 30 seconds and stops the connector past it, and the host then turns it off with an admin alert and a `module.auto_disable` audit row.
- An egress host whose last label is digits or `0x` hex (`127.1`, `0x7f000001`) is refused, since a resolver reads it as an address; an IPv6 literal that carries an IPv4 address is shown as that IPv4.
- `egress_private` cannot be approved until the operator lists the docker host's own addresses in `SLIMM_SUPERVISOR_LAN_DENY`.
- Nothing else may be declared: no ports, mounts, users or capabilities.

The install takes `approved_host_run: {"egress": [...], "egress_private": bool}` beside the permissions.
The token never reaches the admin: the host puts it in the container's environment as `SLIMM_TOKEN` and `SLIMM_BOT_TOKEN`, with `SLIMM_API_URL` and `SLIMM_URL` for the server and `SLIMM_CONNECTOR=1`.
A container the host has to create again gets a new token.

Enable starts the container and disable stops it.
A crash is restarted after 1 second, doubling to 5 minutes, and 5 crashes within 10 minutes turn the connector off with an admin alert and a `module.auto_disable` audit row; enabling it again re-arms it.
Uninstall removes the container and its network, and the volume unless the admin keeps the data.
A host-run connector that declares commands and panels gets `connector.run` like any connector, on the socket its container opens with the token it was handed.
One the host knows is not running (stopped, crashed, refused or turned off after crashing) reads as offline to the member at once, even while its old socket has not closed yet.
`GET /space/dock/modules/{id}/host-run` shows its state to admins and `.../host-run/logs` its recent output, which the host reads from the runtime and does not store.

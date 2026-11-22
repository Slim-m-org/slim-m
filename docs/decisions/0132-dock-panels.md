<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0132 - Dock panels

Status: accepted, 2026-11-22.
Extends: 0090 (section 6, the first slots), 0091, 0100, 0021 (the `app` kind), 0022 (the future `panel` kind).

## Why

Decision 0090 lists a Dock panel among the first slots, and 0022 sketched it as a `panel` kind: an `app` command hosted as a full surface instead of in a message.
Until now a module could draw only inside a message, a profile or a badge, so anything a member wanted to keep in view (a list, a tracker, a status board) scrolled away with the chat.

## Decision

### The manifest

A panel is an extension point, the same shape as `app`:

```json
{ "kind": "panel", "name": "My checklist", "permission": "edit", "command": "checklist", "description": "..." }
```

- `permission` and `command` are required and must name the manifest's own permission and `command` point, exactly as for `app`.
- `name` is a label, shown in the apps menu and the panel's header, and may not repeat among a module's panels.
- At most 2 per module.
- It needs `"addon_api": 6`. The level is the gate: a level 5 server already stores an unknown kind and ignores it (0022), so without the bump a module would install there and silently have no panel. A level 5 server now refuses it with "update the server".

### What the client reads

- `GET /modules/panels` lists, per caller, every panel of an installed, enabled module at level 6 or higher whose permission the caller holds: `[{module_id, command, name, description?, module}]`, the same fields as `GET /modules/apps`.
  A deployment with no such module answers `[]`, and nothing else on the server changes for it.
- The panel runs through the existing `POST /modules/{module_id}/commands/{command}`, which already checks install, enable and permission on every run.
  The first run has an empty `input`; each later one is the `{"action","state"}` the scene sends, as for any interactive scene.
- There is no new event and no stored frame. A panel is the viewer's own: nothing is broadcast, and `private` means nothing here.
- An older client never calls the route and shows nothing; a newer client treats a 404 from an older server as no panels.

### Where it shows

- The entry sits where members already open what modules offer: the composer's Apps menu, under a "Panels" label when apps are listed too. The menu now appears when only panels exist.
- Width decides, never platform (`desktop-vs-mobile.md`):
  - Where the third pane fits (`fitsThreadPane`), the panel docks in that slot beside the conversation at `kThreadPaneWidth`, in place of the member roster, and stays there across channel switches until closed. A docked video moves to its strip. Opening a panel closes a thread docked beside the current channel; opening a thread later takes the slot back and the panel returns when the thread closes.
  - Elsewhere it opens as its own `modalPage` route, `/panel/{module_id}/{command}`: full screen on a phone. This is rule 5, a place the member comes back to.
- The pane appears with the existing panel reveal; its width snaps and is never tweened.

### Keeping the scene

The client keeps each panel's latest scene for the session, outside the pane.
Switching channels, closing and reopening, a thread taking the slot or a resize all come back to the same scene; only the first open runs the empty `input`.
A module that fails or times out on that first run shows the standard error state with Retry; a failed action shows inline under the scene, as everywhere else.

### Redraws

`refresh_ms` (2 to 60 seconds) is honoured for a panel by the client, which runs the command with the action `refresh` and the held state while the panel is on screen and the window is visible, and for at most half an hour after the viewer last pressed something.
The host-driven chain from level 3 stores and broadcasts a shared frame, which a private panel does not have, so this is the same contract driven from the other end rather than a second one.

## Not decided here

- Panel state that survives a restart of the app. A module that needs that keeps it in its own storage keyed by the caller.
- More than one panel docked at once.
- Run `context` for a panel (`channel_id`, `voice_channel_id`). A panel runs with none in this level.

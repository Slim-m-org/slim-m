<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0068 - One app, several servers, switched from the top left

Status: accepted
Date: 2026-10-17

## The ask

The owner asked: "space switching? what if I have multiple spaces that I want to be a part of, can I easily switch? can we create that feature and do it like slack workspaces where we click top left and change workspace?"

Decided the same day, not to be re-asked:

- One app signed into several slim-m servers at once, switched from the top left of the channel rail.
- Every signed-in server keeps its unread badges and notifications live while another is in view.
- A voice call keeps running across a switch and shows as a pill that returns to it.
- DMs stay per server.
- Client only. No server change.

## What this does not change

[0001](0001-owner-decisions.md) item 4 stands: one deployment is one community.
Nothing here puts two communities on one server.
The client simply holds several independent sessions, one per deployment, the way a browser holds several tabs.

[0036](0036-security-check-on-first-join-only.md) stands: the identity pin is `server_identity:<origin>` in the key store, already keyed by origin, so it is per server without any change.
Adding a server goes through the same `confirmServerIdentity` path as any first join.

## Account model

An account is one server origin plus the session issued by it.
There is at most one account per origin, and one user per account.
Two users on the same server is out of scope.

The account index is one key-store entry, `slimm.accounts`.
It holds a JSON list of `{origin, serverUrl, dbFile}` and the id of the active account.
It holds no secrets.

Each session lives under its own handle, `session:<origin>`, with the same `TokenPair` JSON the legacy handle used.
The origin is `scheme://host[:port]`, lowercased, with no path.

An account may exist without a session.
That is the signed-out state: the server is remembered and sign-in is shown for it, exactly as a signed-out install behaves today.

## Migration from the single pair

The legacy handles are `session_token_pair` and `server_url`.
On the first launch that finds no `slimm.accounts` and a legacy `server_url`, the client writes one account for it.
If a legacy session exists it is copied to `session:<origin>`.
The legacy handles are deleted only after the new entries are written and read back, so an interrupted migration is re-run, never half-applied.
They are deleted rather than kept, because the server rotates refresh tokens with reuse detection and a stale copy replayed by an older build would revoke the family.

The migrated account keeps the database file `slimm.sqlite`, so no cache is copied or lost.
Every account added later gets `slimm-<hash of origin>.sqlite`.
On web the database name is the same string without the extension.

## Never delete credentials on a read failure

Restoring an account reads its session handle.
A read that throws, or JSON that does not parse, leaves the stored value in place and starts that account signed out for this run.
The restore is retried the next time the account is activated.
Only an explicit sign-out, a rejected refresh, or removing the account deletes a session.
This is deliberately the behaviour of the in-flight `fix/session-restore` change, so the two merge without disagreeing.
The legacy `restoreSession` is left untouched for that reason and still serves a container with no account host.

## One provider container per account

The provider graph is not rebuilt in place on a switch.
Every account gets its own `ProviderContainer`, so the whole existing graph (session, api, database, sync, push, voice, router, notifiers) is instantiated once per account with no code that has to know about the others.
That is the isolation guarantee: nothing in a container can read another account's data, because no provider is shared.

An in-place rebuild was rejected.
Most controllers are notifiers that read the session once and cache; invalidating them one by one is the same class of bug as the "stale identity survives a sign-in" fixes already in `SyncController` and `EffectiveMe`, repeated for every provider.

An `AccountHost` outside Riverpod owns the containers.
Each container gets an `AccountSlot` override telling it which account it is, which session handle and database file to use, and how to reach the host.
A container with no slot behaves exactly as before, which is how every existing test runs.

The root widget mounts the active container with `UncontrolledProviderScope`, keyed by the container.
A switch changes which container is mounted.
The inactive containers stay alive and headless.
Each keeps its router, so returning to a server lands where the person left it.

### Amended 2026-11-19: every container keeps a scope mounted

The root now keeps one `UncontrolledProviderScope` mounted per tracked container, for as long as the host tracks it.
The active one has the app under it and the others have nothing, so a switch still unmounts the whole app tree of the account that leaves the screen.

It has to be this way because of how Riverpod 2 schedules work.
A container with a scope mounted hands its queued refreshes and disposals to that scope, to run on its next build.
When the scope unmounts with something queued, which a switch always causes because every widget of the leaving account stops watching in that same frame, the queue is never run and the container never queues again.
From then on nothing `autoDispose` in that account was ever disposed, and a provider derived from another stopped refreshing its listeners, on screen or off, until the app restarted.
Closing the switcher did the same to an account out of view, because its rows scope that account's container to show its name and icon.

What it costs, in two parts.

A hidden window draws no frames, so the queue of every container waits until the window shows again.
That was already true of the account on screen; it is now true of the ones out of view too, which used to run theirs on a timer for as long as they had never been shown.
A notifier, a stream and the socket do not go through the queue.
A listener on a derived provider does: it hears a change only after the provider rebuilds, which is on the next frame.
So anything that must act while the window is in the tray listens to a select straight off the notifier, the `...AtOnce` listenables (`voiceFlagsAtOnce`, `voiceParticipantsAtOnce`, `appFocusedAtOnce`).
The host's own call tracking, the deafen of a restored call and the viewing report were moved to them with this amendment; the tray, the call restore record and the screen overlay already used them.
What still waits for a frame in a hidden window, and is left that way: the activity publisher hearing that the person went hidden on another device.
The server applies that rule itself, so nothing is shown that should not be.

An account out of view now asks the window for a frame whenever its queue has work, and with nothing on screen changed that frame is drawn for nothing.
The soak harness counts them (`bench.background_frames.*`, `docs/soak-harness.md`): about one frame for a message, about one for a presence change, none for most typing starts, against none with the window at rest.
The rate follows the rate of events and cannot pass the display's: an account that receives five events a second asks an otherwise idle window for about five frames a second.
What one such frame costs in a release build, in CPU and in a GPU that could otherwise sleep, has not been measured.
If it turns out to matter, the remedy is to coalesce at the source of the busiest derived providers, the presence map and the message extras, and not to take the scopes away again.

The rows that name another server, in the switcher, the call pill and the share step, used to mount a second scope for that server's container.
They now listen to the container instead (`ServerIdentity`), so the root's scope is the only one a container ever has.
A second scope that left the tree in the same frame as a switch kept a run it never made, and a debug build stopped on it.
See `docs/internals.md`, account scopes.

## What is global and what is per account

Global, shared by every container because they live in `SharedPreferences` and are re-read when a container is activated: UI scale, motion, rail width, app lock, and voice device preferences.
Theme, density, sounds and the other message and notification preferences became per Space in [0070](0070-space-scoped-settings.md).

Per account, because the data is keyed by server-issued ids or lives in the account's database: drafts, read state, the channel list, per-channel notification settings, the notification schedule, blocks, and everything fetched from the server.
UUIDv7 ids do not collide across servers, so id-keyed preferences are already safe.

The desktop tray follows the accounts: its call controls act on the account that is in a call, and its status and preferences items on the one on screen.

## Inactive servers stay live

Each account's container runs the same bootstrap as the active one, minus the window: restore session, `SyncController` (REST catch-up plus the live socket), `PushController`, the desktop notifier, the notification chime and the other session-lifetime watchers.
That gives live unread state and notifications for free, with no second code path to keep in step.

The desktop notifier used to stay quiet whenever the window was focused, because the rail already shows unread.
For an inactive account the rail is not showing it, so that gate now applies only to the active account.

The switcher badge is a stream over the account's own rail channels, filtered through `unreadIndicatorFor` so a muted channel does not light it.
A mention shows a count, plain unread shows a dot.

### What it costs

Per extra account: one WebSocket, one SQLite file, one set of in-memory controllers, and one push registration with that server.
The REST catch-up at launch runs once per account rather than once.
Idle sockets are cheap, and the server already treats a device with no viewing report as not looking, so it keeps pushing.

On a phone the OS suspends the socket in the background the same way for every account.
Delivery then falls back to push, which is registered per account, so a backgrounded phone is notified by each server independently.
A phone with many accounts pays the launch catch-up and the foreground sockets in proportion, which is why the list is not capped but the cost is documented here.

## Voice across a switch

The call lives in its container's `VoiceController`.
That container is never disposed on a switch, so the LiveKit session, heartbeat and audio continue untouched.

The host watches every container's voice flags.
While another account has a connected call, the active account shows a pill, "In a call on <server>", and tapping it switches back.
Joining a call on one account while another has one leaves the older call first, because the voice stack is one microphone and one output.

### Amended 2026-11-16: where the pill steps aside

The pill floats top-centre, and below the app bar on a phone.
There it covered what sat under it: the rail's search field, the channel topic, and on a phone the "Offline, retrying" bar.
It now hides wherever something else on screen already names the same call:

- The rail's call row, on a wide window and in a phone's drawer (decision 0111).
- The phone's call strip, at the bottom of a conversation or of a full-window page.
  With no call in this community, the strip shows the other community's call the way the rail's row does: its channel, the community's name leading the second line, mute, deafen and Leave acting on that call, and a tap that switches to the community and opens the call there.
- The composer's slim call pill, which takes the strip's place in a phone conversation while the keyboard is up.
  With no call in this community it shows the other community's call the same way, in one line: the community's name ahead of the timer, mute and Leave acting on that call, and the same tap.

Each of these counts itself in `callElsewhereShownProvider` while it is on screen, and the pill hides while any is counted.
A place under a pushed route stays mounted but is not on screen, so it does not count.
The pill still shows where none is on screen: a full-screen canvas on a wide window, and a route pushed over the shell that has no strip of its own.

## Adding and signing out

"Add a server" mounts a new, empty container at onboarding and the existing sign-in flow runs unchanged inside it.
The account is created when the server is chosen, so a relaunch mid-add still knows it.
Choosing an origin that already has an account switches to it instead of adding a duplicate.
Backing out of an add removes the account if it never signed in.

Signing out from the switcher ends that account's session on its server and removes it from the list when another account remains.
The last account stays as a signed-out entry, as an install does today.

## Built, and what is left

Built: account index and migration, per-account session handles and database files, a container per account, the switcher menu and sheet, Ctrl+1 to Ctrl+9, unread badges from live background sync, the call pill, add and sign out.

Also built: notification taps and links land on the right server.
A desktop banner carries its server and channel as its payload, and a tap switches to that server before opening the channel.
A push carries only a channel id, so the app opens the channel on the account whose local store has it, and on the one on screen when none does.
A message link switches to the server it names, and an invite for a server not in the list opens the add flow with the invite filled in.
Diagnostics write to one log shared by every account, and every account's session endings are recorded in it.

Left, each a real gap rather than a deferral for its own sake:

- A push for a channel the device has never synced cannot name its server, so it opens on the account on screen. Naming the server in the push envelope needs a server and native change.
- Android background notifications are still sealed and carry no channel, so a tap only raises the app.
- Real-device behaviour of several sockets and push registrations on mobile has not been measured.

# 0090 - Modules become the extension surface

Status: accepted (design; implementation phased)
Date: 2026-10-23
Extends: 0021 (modules and the Dock), 0022 (module extensibility), 0023 (mediated host capabilities), 0046 (more than one module source)
Revises: 0035 (when something is a module and when it is a bot), see "A module is a manifest plus a logic provider"

## The ask

The owner, 2026-10-23:

> the goal is for them to be add on functionality that people can choose to opt into instead of having bloated app, so by default when they spin up a space they have just a simple feature messaging app

> I dont want to always resort to bots, yes we could solve alot of issues with bots but those dont feel as integrated as it would be if it was running on/in with the server

> the ideas i proposed are just spitballing, so dont limit your solution on my requirements the goal is to be dynamic for what someone might want

The examples that prompted it were a word and regex filter applied before a message is sent, finer permissions, XP for time in voice with a bar on the profile, a game server panel, code execution on the canvas, games in a call, and remote desktop tiles.
They are probes for what is missing, not a feature list.

## What is wrong today

A module is a function a member triggers: input in, text or a scene out.
Checked against the code on 2026-10-23:

- The host calls a module only when a member acts.
- The capabilities that exist are `kv.store`, `message.post` and `net.fetch`.
- `kv.store` holds at most 256 entries and 64 KB per module, with no queries.
- The extension point kinds that exist are `command`, `slash-command`, `app` and `code-block-runner`.
- `hub::Event` has roughly 60 variants (messages, reactions, voice joins and leaves, member joins, role changes, canvas changes), and none of them reach a module.
- `VoiceParticipantJoined` and `VoiceParticipantLeft` carry only the channel and the user.
  The server stores no voice sessions, only DM call records.

So a module can be a tool members run, but never a behaviour a space has.
Decision 0021 already named the missing seams (a command, a message action, a scheduled job, a settings panel) and decision 0022 deferred host-to-module events.
This record is that deferred work.

## The principle, unchanged

slim provides the module system and never a module's behaviour.
Core gains generic slots and hooks, each reviewed on its own.
It never gains a line that knows what XP, a word filter or a game is.
The test stays the one from 0021: with no module installed, slim has no notion of the feature, and removing the module removes it cleanly.

## A module is a manifest plus a logic provider

The manifest says what the module contributes: subscriptions, interceptors, settings, permissions, UI slots and data.
The logic provider is one of two things:

- **WASM**, sandboxed inside the server, for logic that needs only events and its own data.
- **A connector**, an external program the host runs, for anything that needs a network, a secret or a long-lived process.

Integration comes from the contribution points and the install experience, not from where the code runs.
A bot that has a manifest is a connector, so it gets Dock install, host-rendered settings, permissions and UI slots like any module.

This revises decision 0035.
Its first three questions (needs a secret or the network, runs on its own schedule, needs a visible identity) now choose the provider, WASM or connector.
They no longer decide whether the feature is integrated.
Its worked cases still stand as provider choices: a Jellyfin watch party is a connector with a module surface, and a mini-game is WASM.

## The primitives

Each is one bounded contract with its own review, added in the order under "Phasing".

### 1. Event subscribers and durable logs

The host pushes events to a module after they commit.
A subscriber cannot block or change anything.
Push is best-effort: the hub is an in-memory broadcast, so a restart or a lagging queue can lose events, and the contract says so.
Each push carries a stable id the host mints, so a module can dedupe a repeat.
A module declares the events and fields it needs in its manifest, so the consent screen shows them and an update that asks for more prompts again.
The queue is bounded per module, drops the oldest first, and counts what it dropped.

Anything that must not be lost is read instead of pushed.
The host exposes durable logs (voice sessions first) that a module reads with a cursor, so after a restart it catches up exactly once.
A durable outbox written in the same transaction as every action was considered and declined for now: it touches every message, edit and voice write path.

Voice time needs sessions.
`voice_call_events` (migration 0108) is only a join and leave log pruned at 30 days.
The host adds a voice sessions table (user, channel, joined, left, time alone) built from the same webhook path, closed on a missed leave, a room ending, a stale heartbeat or a restart, and the durable log reads from it.

### 2. Interceptors

An interceptor runs before an action and can reject it, annotate it or rewrite it.
They exist only at a short named list of points, starting with pre-send and pre-edit.

- **Phases run in a fixed order:** reject, then annotate, then rewrite.
- **Within a phase,** an integer priority orders modules, ties broken by install time, and the admin sees and edits the order.
- **A rewrite is passed down the chain.** A reject stops it and shows the sender a reason.
- **Each module has a time and fuel budget,** around 50 to 100 ms, and the whole chain has a cap per message.
- **Fail-open is the default.** A trap, a timeout or an exhausted budget lets the message through unchanged and counts as a failure.
  An admin can set a given hook to fail-closed.
- **A circuit breaker disables a module after repeated consecutive failures** and tells the admins.

Every way a message can be created or edited has to pass through the same chain, or a filter can be bypassed.
On 2026-10-23 the direct `send_message` callers found were the messages route, webhooks and the welcome post, with a separate edit path.
The module, bot and import paths were not traced, so the first interceptor card starts by enumerating them.

A permission check hook is the one other early interceptor.
It is deny-only: a module can restrict an action and can never grant one.
It uses the same budget, breaker and fail-open default.

### 3. Ticks

These already exist: a manifest `schedules` list with the `schedule` capability, a 5 minute minimum, at most 8 per module, run by a 60 second sweep as the module's own principal.
Phase 1 does not change them.
A faster tick, or a tick that does not post, is a later gap-fill.

### 4. A data store per module

Each module gets its own SQLite file under the data directory, with a size cap.
The manifest declares tables and typed columns, and the module calls structured operations (insert, upsert, update, delete, get, query with filter, order and limit, count, sum, increment).
The host builds the SQL itself, so a module cannot inject SQL, attach another database or open a path, and no `unsafe` code is needed.
Schema changes are additive only in the first version.
Raw SQL behind a SQLite authorizer can be added later without breaking a module written against this API.
Uninstall keeps the file unless the admin chooses to delete it, and backups include the files.
`kv.store` stays for simple cases.

### 5. A settings schema

The manifest declares typed settings: type, default, range and whether a value is secret.
The host renders the admin screen from it, so a module needs no settings UI of its own.
Secret values stay with the host, which injects them into approved `net.fetch` calls, so a module can call an authenticated API without ever seeing the key.

### 6. UI slots and tile types

The client cannot run downloaded code on every platform, so a module's UI is data the client renders.
The vocabulary is closed and versioned, in the style of Slack's Block Kit.

- Every node has a `type`, and every surface a version.
- A client that does not know a node type ignores it or shows its plain-text fallback.
- Fields are only ever added, never repurposed.
- Interaction is a named action routed back to the module, never client code.

The first slots are a profile section, a member badge, a settings page (generated from the schema) and a Dock panel.
Later slots are a canvas tile, a call scene and a message decoration.
Surfaces that need real pixels (a video stream, a terminal, a game board) become generic tile types added to the client one at a time.
The client does not run module-supplied web code.

### 7. Permissions

Module-declared permissions already exist (0021).
Channel-scoped overwrites for them stay a later extension.

### 8. Connectors

A connector is an external program with a manifest.
The host gives it a scoped token as a bot principal holding only the permissions the admin approved, and mounts its manifest-declared settings, permissions and UI into the app.
The host starts and supervises it, which is the owner's choice and the largest new risk in this record, so the requirements below are part of the decision.

### 9. Import and export

An admin can install a module from a local file and export an installed module as one, in addition to the official source and community sources (0046).
A file import uses the same manifest validation, the same consent screen and the same "unreviewed" label as a community source.

### 10. A versioned add-on API

Every manifest declares a range against a stable add-on API version that is separate from the app version.
The host refuses to load a module outside the range and says why.
A removed contract keeps a stated support window.
Slack retiring its app steps with no migration path, and Rocket.Chat's runtime change breaking apps in 7.0, are the failures to avoid.

## Decisions (owner, 2026-10-23)

| Question | Decision | Alternatives declined |
| --- | --- | --- |
| Who runs connectors | The host runs and supervises them, with as many protections as we can build | Admin-run only, which needs no new trust surface but is two install steps |
| Where modules come from | The official repository and community sources as today, plus local file import and export | Official only; no file import |
| Interceptor failure | Fail open, the admin can switch a hook to fail-closed | Fail closed everywhere; manifest-only choice |
| Module data | A SQLite file per module | Tables in the main database; a larger key-value store |
| Pixel-heavy UI | Data only, plus tile types added to the client over time | A sandboxed web surface; deciding later |
| Event delivery | Best-effort push, plus durable logs read with a cursor | A durable outbox for every event; push only |
| Module run lane | Events and schedules get their own small concurrency cap, apart from members' commands | Sharing the global gate; raising it |
| Data API | A structured operation API, raw SQL later | Raw SQL behind an authorizer (needs `unsafe`); raw SQL behind a hand-written filter (easy to bypass) |

## Requirements for host-run connectors

These are conditions on building it, not a description of something built.

- It is off unless the operator configures a container runtime, so a default self-host install has no such access.
- The server reaches the runtime through a restricted interface that allows only creating, starting, stopping and removing containers labelled for slim, and a module's container never sees the runtime socket.
- Containers run as a non-root user with a read-only root filesystem, no extra privileges, all capabilities dropped, the default seccomp profile, and CPU, memory and process limits.
- Each connector gets a private network whose egress is limited to hosts the admin approved, none by default, and no host mounts except its own data volume.
- The image is pinned by digest in the manifest and pulled only from registries the operator allows.
- The consent screen names the image, ports, egress hosts, volumes and token scope.
- The host shows health and logs, restarts with backoff, and disables a connector that keeps crashing.
- Uninstall removes the container, revokes the token and removes the volume unless the admin chooses to keep it.
- Whether the runtime client lives inside the server process or in a small separate supervisor is decided in its own record before the build, because it decides what a compromised server can reach.

## Phasing

Each phase ships with a proof module in the add-ons repository, so the contracts are judged by a real use.

1. **Reactive modules.** Event subscribers and durable logs, the data store, the settings schema, voice sessions, and the profile section and member badge slots.
   Proof: an XP module that earns XP from voice time, keeps it in its own store, takes its rates from settings and shows a bar on the profile.
2. **Interceptors.** The interceptor chain for pre-send and pre-edit, the deny-only permission hook, ordering, budgets, the breaker and the admin order screen.
   Proof: a word and regex filter module.
3. **Connectors and portability.** The connector manifest and scoped token, the host-run requirements above, file import and export, and the versioned add-on API.
   Proof: a game server panel module.
4. **Surfaces.** Canvas tiles, call scenes, Dock panels and shared room state for games.
   Proof: a module that puts a game in a call.

## What stays out of core

The XP rules, the filter rules, every game, and the permission policy logic.
Core owns only the contracts above.

## Risks and what the survey could not verify

- Every hook and slot is public API for as long as modules rely on it, so a new one is added only when a second module needs it.
- The WASM runtime is an interpreter, so a module on a hot path pays for it, which is why interceptors have a budget and a breaker.
- Host-run connectors are the biggest new attack surface in this record, and they are gated on the requirements above.
- The survey that informed this record covered Mattermost, Rocket.Chat, Zulip, Matrix, Discord, Slack, proxy-wasm, Shopify Functions, VS Code, Figma, Home Assistant, Paper, Foundry, Nextcloud, WordPress and Discourse.
  Several documentation pages could not be fetched, and a number of details came from memory.
  Treat its claims about hook ordering, timeouts and quotas in those systems as unverified, and rely on the shape of the lessons, not the numbers.

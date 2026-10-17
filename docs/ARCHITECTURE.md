<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Architecture

A ten minute overview for someone about to read the code.
It says where things live and how they fit, and leaves the reasons to [BRIEF.md](BRIEF.md), [STRATEGY.md](STRATEGY.md) and the [decision records](decisions/README.md).
[CLAUDE.md](../CLAUDE.md) has the code map this page expands.

## The pieces

```text
clients (Flutter: Linux, Windows, macOS, Android, iOS, web)
   |  REST (durable writes)        |  WebSocket /ws (fan-out, ephemeral signals)
   v                               v
slimm-server: one Axum process, SQLite (WAL) on disk, attachments on disk
   |-- LiveKit SFU (voice, screen share): the server mints tokens, LiveKit calls back on /voice/webhook
   |-- push relay (separate Go service): the server sends sealed payloads, never plaintext
   |-- module runtime: wasm modules run inside the server process
   '-- Dock registry: a GitHub repo read from raw.githubusercontent.com

bots and webhooks: programs someone else runs, calling the same REST and WebSocket surface
```

One deployment is one community.
The server is a single process serving HTTP and WebSocket from one port, and the database is an embedded SQLite file (`SLIMM_DATABASE_PATH`).
The push relay lives in its own repository; the server's side of it is `crates/slimm-server/src/push/`.

## The server

Everything is in the library crate under `crates/slimm-server/src/`, and `main.rs` only picks an entry point, so integration tests can drive the real router.
`lib.rs::run` loads `Config` from `SLIMM_` environment variables, opens the database (running migrations), builds `AppState`, starts the background sweeps and serves.

| Path | What it owns |
| --- | --- |
| `http/` | Axum handlers, one module per feature, plus `http.rs` for routes and `AppState` |
| `store/` | SQL, one module per feature, mirroring `http/`; methods are inherent on `Store` |
| `hub.rs`, `hub/` | The fan-out hub, the `Event` type and the memory admission guard |
| `http/ws.rs`, `http/ws/` | The WebSocket endpoint and its frame types, kept separate from the internal `Event` |
| `auth.rs`, `http/auth/`, `totp.rs`, `http/totp.rs` | Sessions, password hashing, refresh rotation, TOTP |
| `permissions.rs`, `store/permissions*.rs` | The permission bitfield and its per-channel evaluation |
| `ratelimit.rs`, `ratelimit/` | Rate classes and the limiter |
| `voice/` | LiveKit tokens, rooms, rings, the roster |
| `push/` | Deciding who to notify, sealing the payload, calling the relay |
| `module_runtime/`, `http/dock*` | The wasm host (wasmi), capabilities, the Dock |
| `code_runner.rs`, `code_runner/` | The broker to an optional Piston instance |
| `sweeps.rs` | Background cleanup: tokens, attachments, canvas ops, calls, rings, retention |

A new feature usually means a matching pair in `http/` and `store/`, a route in `http.rs`, and an entry in `schema/openapi.yaml`.

Two server rules that are easy to miss:

- Whether a push carries the message text is an account setting that falls back to `DEFAULT_PUSH_PREVIEW` in `src/notifications.rs`, resolved at send time ([0054](decisions/0054-push-preview-default-on.md)).
- A migration that adds a uniqueness rule must repair the rows that already break it, because deployments have real data and a migration that fails stops the server.
  Migration 0095 (case-insensitive usernames) renames the losers and records each in `username_collision_renames`, which [OPERATING.md](OPERATING.md#usernames) explains for operators.

## The client

`client/` is a Flutter workspace of seven packages, layered bottom-up: `api` (wire types and transport, no Flutter), `data` (the drift local store and sync), then `design_system`, `platform`, `rtc` and `voice_canvas`, and `app` on top.
Nothing below `app` imports from it.
Inside `app/lib/src/`, each feature lives in `features/<feature>/` with its own `widgets/`, `providers/` and `screens/`: auth, canvas, channels, composer, emoji, members, messages, modules, palette, settings and voice.
The top-level `widgets/`, `providers/` and `screens/` are the shared layer: the home shell, sync, push, app lock and generic pieces two or more features use.
State is riverpod and routing is go_router (`routing/`).

## The hub

`hub.rs` is two broadcast channels, one durable and one ephemeral, not a router per scope.
REST handlers publish an `Event`; each WebSocket connection subscribes to both channels and filters down to what its user may see.
Fan-out order across concurrent writers is best effort, so a client applies durable events strictly by per-scope `seq`.
A subscriber that lags past `CHANNEL_CAPACITY` is dropped and its client resyncs over REST.
An ephemeral subscriber that lags just skips forward, because losing a stale cursor position is cheaper than a resync.

## How a message travels

1. The client generates a UUIDv7 for the message and sends `POST /channels/{id}/messages` (`http/messages.rs`).
   The id makes the send idempotent, so an at-least-once retry never duplicates.
2. The handler checks view and send permission in that channel, then `Store` inserts the message.
   The per-channel `seq` comes from `channel_seq_counters` inside the same transaction as the insert, so it is gap-free and monotonic.
3. Only a fresh send (not an idempotent retry) goes on: mentions are resolved, and `Event::MessageCreated` is published on the hub.
4. The hub delivers it to every subscribed connection, and `push` decides whether to notify devices that are not looking, then calls the relay in a detached task.
5. The receiving client gets the frame over `/ws` (`api/lib/src/events_connection.dart`) and writes it through `MessageStore` (`data` package).
   Live push and REST catch-up both go through that one store, so they can arrive in any order or repeat and the result is the same.
6. On reconnect the client does not trust the live stream until it has caught up by `seq` over REST (`app/lib/src/providers/sync_controller.dart`).

A WebSocket is opened with a single-use ticket from `POST /auth/ws-ticket`, then a `hello` frame.

## Identity and ordering

Identity is a UUIDv7 for users, channels, messages and the rest, generated by the client where it needs optimistic local echo.
Ordering is a per-channel (or per-stream) monotonic `seq`, never a timestamp.
Edits and deletes ride a separate op stream with its own `seq`, which is how an offline client reconciles a change it missed.
Canvas operations have their own per-channel op sequence.

## Auth in one paragraph

`POST /auth/login` returns tokens, or for an account with two-factor on, a `totp_challenge` that `POST /auth/totp/verify` redeems with a code or a recovery code (decision [0048](decisions/0048-totp-two-factor.md)).
Refresh tokens rotate on use.
Recovery is an admin-issued one-time reset code; there is no email.
A bot authenticates with a long-lived token as a user-shaped principal, and an incoming webhook is a URL that is itself the credential.

## Voice

The server never carries media.
It derives the LiveKit room name from the channel id, mints a token whose grants come from the permission bitfield, and listens for LiveKit's webhook on `/voice/webhook` to know who joined and left (decision [0032](decisions/0032-voice-participant-webhooks.md)).
With no LiveKit settings the server answers 501 on every voice route, and that is a supported way to run.

## Extending a deployment

Pick by the test in decision [0035](decisions/0035-module-or-bot.md).
A webhook (0030) is the cheapest way to get a tool's output into a channel.
A bot ([building-bots.md](bots/building-bots.md)) is a program you run with its own identity.
A module ([building-modules.md](modules/building-modules.md)) is wasm that runs inside the server under fuel, wall-clock and memory limits, and gets host capabilities only by an admin's approval.

## The client

A Dart pub workspace under `client/packages/`, layered bottom-up:

| Package | Role |
| --- | --- |
| `api` | Wire types and transport; no Flutter |
| `data` | The drift local store and sync; `database.g.dart` is generated and committed |
| `design_system` | Tokens and shared widgets |
| `platform` | Per-OS channels: notifications, keystore, install format |
| `rtc` | LiveKit and call handling |
| `voice_canvas` | The Voice Canvas |
| `app` | Screens, routing (go_router), state (riverpod), `desktop/self_update` |

Wire types and the drift tables are hand-written on both sides; `schema/openapi.yaml` is the contract, not a generator input.

Three client limits that are deliberate rather than bugs:

- Android sweeps its share temp folders only on the next share, so the chooser can still read them; iOS and desktop delete in a `finally`. Exported images can therefore sit in the cache until the next share.
- Flutter's `showDialog` stays reachable off Linux, in `in_window_dialog.dart`, on purpose.
  Only Linux turns windowing on, so other platforms call `showDialog` and Linux uses the in-window route.
  When nothing reached `showDialog`, the macOS AOT snapshot generator crashed (`Class with illegal cid` in Flutter's `_window_macos.dart`) and 0.91.0 shipped without a macOS build.
  `no_bare_show_dialog_test.dart` and `sheet_not_windowed_test.dart` pin it.
- A message deep link resolves by walking at most 10 pages (about 500 messages) of channel history, so an older link lands on the "unreachable" notice.

## The contract

`schema/openapi.yaml` is the source of record for the wire protocol.
`crates/slimm-server/tests/openapi_contract.rs` fails when a documented route and the real router drift apart.
A new route also needs a client binding, or the `schema_coverage` and `app_reachability` gates fail.
[CONTRIBUTING.md](../CONTRIBUTING.md) lists the rest of the gates.

## Where to read next

- [OPERATING.md](OPERATING.md) for running a deployment, and [deploy/README.md](../deploy/README.md) for the compose walkthrough.
- [ci.md](ci.md) for what every workflow does.
- [decisions/](decisions/README.md) for why things are the way they are.
- [design/design-language.md](design/design-language.md) and [design/desktop-vs-mobile.md](design/desktop-vs-mobile.md) before touching UI.

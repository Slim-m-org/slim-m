<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0104 - Modules hear a call as text, from a listener the operator runs, only while everyone in it agrees

Status: accepted (design; implementation phased)
Date: 2026-11-02
Extends: 0090 (modules as the extension surface), 0091 (phase 1 contracts), 0100 (add-on API levels), 0067 (install consent), 0023 (mediated host capabilities)
Keeps: 0066 (core stores no audio, transcript or speaking activity)

## The ask

The owner, 2026-11-02: "I want modules to be able to access voice calls audio lets work on implementing that".
His note on the Planka card "Module: an opt-in call transcript", 2026-10-26: "some sort of opt in call transcript would be cool, id prefer to keep it out of core".
The backlog already said the same in 2026-08: "ship speech-to-text only as an optional module, never required for a lightweight self-host" (`docs/BACKLOG.md`).

## What exists today

Checked against `v122/integration` at 682d40944 on 2026-11-02.

- A module is WebAssembly run by `wasmi`, an interpreter, inside the server (`module_runtime/host.rs`).
  Every run builds a fresh store, calls `run` once with JSON in and JSON out, and is bounded by fuel (default 50 million, at most 2 billion), memory (default 16 MiB) and a wall clock (default 1 s, at most 10 s).
  A reply is at most 1 MiB, and a run makes at most 128 host calls.
- Runs nobody invoked (events and schedules) share a background lane of 2 concurrent runs (`module_runtime/gate.rs`).
  Events are queued per module, 256 deep, oldest dropped first, and delivered as `@event` runs (0091).
- A module cannot hold a connection open, cannot run between calls, and has no streaming input.
  A module that wanted raw audio would get it as JSON text in 1 MiB pieces, one interpreter run per piece, two at a time across every module on the server.
- The server never touches media.
  It mints LiveKit tokens and calls the room service over HTTP (`voice/token.rs`, `voice/room_admin.rs`), and learns who is in a call from LiveKit webhooks (0032).
- The server image is one static musl binary on distroless, and `server-ci.yml` fails it past 20 MiB.
  The LiveKit SDKs that can subscribe to a track are built on libwebrtc, which ships prebuilt for glibc and is many times that size.
- Bots already join calls as participants with the Python LiveKit SDK, `livekit==1.1.20`, in `slim-bots` (`slimbots/voice.py`), with a fake-based suite and a real-LiveKit suite.
- LiveKit runs as `livekit-server` 1.13.11 (0102), single node, with no Redis and no egress service deployed.
- Module principals, per-module posting channels (`PUT /space/dock/modules/{id}/schedule-channel`), the consent sheet (`dock_host_access_card.dart`), the breaker and the add-on API range (0100, level 3) all exist and are reused here.

## Decision in short

- **What a module gets:** text.
  Speech-to-text segments, each with the speaker's user id and start and end times, delivered as events.
  A WebAssembly module never receives audio samples.
- **Where the media runs:** in a separate listener service the operator chooses to run, `slimm-listener`.
  The server asks it to join a call as a hidden, subscribe-only participant, hear only the people who agreed, and turn their speech into text with whisper.cpp on the same host.
  The listener hands text back to the server, and the server delivers it to the one module the call agreed to.
- **Consent:** a new `call.audio` power with the strongest install warning, an admin-chosen list of voice channels per module, and a per-call agreement from every person in the call.
  Nobody's audio reaches the listener's transcriber until that person said yes, everyone in the call sees it while it is on, and anyone in the call can stop it for everyone.
- **Core keeps nothing:** no audio, no text, no consent history.
  The session lives in memory and ends with the process.
  What the module keeps is the module's business, and the module has to say what that is in words every person is shown before they agree.

## What a module gets, and why text

| Option | Verdict | Why |
| --- | --- | --- |
| Live mixed PCM stream to the module | Declined | A module cannot hold a stream. One second of 16 kHz mono PCM is 32 KB, about 43 KB as base64 in JSON, so a call would cost dozens of interpreter runs a second on a lane of two. Decoding or analysing it in an interpreter under a fuel cap is not realistic. |
| Per-speaker PCM streams to the module | Declined for WebAssembly | The same limits, times the number of speakers. Raw per-speaker audio is the right shape for a connector (0090 primitive 8), so it is phase 5, behind the same per-call consent. |
| Post-call recordings | Declined for core | A recording is audio stored on the server, which is exactly what 0066 rules out. A connector that wants one records the stream it is handed, in its own volume, and says so in its consent text (phase 5). |
| Server-side speech-to-text segments with speaker ids | **Chosen** | The heavy media work stays in a native process. A module gets a few hundred bytes per utterance, a handful of runs a minute, inside the event contract that already exists. It is also what the first consumer, a transcript, needs. |

Segments are per speaker, because the listener transcribes each person's own track.
That gives speaker attribution for free, with no diarization model and no guessing, and overlapping speech stays separate.

A WebAssembly host call that transcribes audio a module hands it, for example a voice-message attachment, is useful later (`speech.transcribe`, phase 4).
It is not how call audio flows: passing call audio through a module only to hand it back to the host costs copies and fuel for nothing.

## Where the media path runs

### The listener

`slimm-listener` is a small Rust service in this repository (`crates/slimm-listener`), built as its own Cargo workspace with its own lockfile and image, `ghcr.io/slim-m-org/slim-m-listener`.
It is optional in the same way the code runner (0026) and the push relay are: a deployment that does not set `SLIMM_LISTENER_URL` has no call audio, and the `call.audio` power cannot be granted there.

- It uses the LiveKit Rust SDK (`livekit` crate, libwebrtc underneath, the same core the Python SDK in `slim-bots` wraps) to join a room with a token the server mints.
- The token is room-scoped, `hidden: true`, `canSubscribe: true`, `canPublish: false`, `canPublishData: false`, with a 120 second TTL, and identity `listener-<session id>`, which never parses as a user id, so the webhook and roster paths that map identities to users skip it.
- `autoSubscribe` is off.
  The listener subscribes only to tracks whose source is `MICROPHONE` and whose participant is in the session's include set, and it unsubscribes the moment an identity leaves that set.
  Screen-share audio, camera, data and every bot's audio are never subscribed.
- Each subscribed track becomes a 16 kHz mono PCM stream (the SDK's audio stream resamples), which an energy-based endpointer cuts into utterances: 20 ms frames, a threshold that follows the track's own noise floor, 600 ms of trailing silence ends an utterance, shorter than 400 ms is discarded, longer than 15 s is cut.
- Each utterance goes to the transcriber, and its text comes back to the server as one segment.
  PCM is held only in memory, only until it is transcribed, and is never written to disk.
- With no control connection from the server, the listener leaves every room within 5 seconds.

### Speech to text

The transcriber is whisper.cpp through the `whisper-rs` binding, on the CPU of the host the listener runs on.
No audio and no text leave the operator's machines.
There is no cloud engine and no setting for one; an operator who wants one is outside this design.

- The model is a file the operator provides at `WHISPER_MODEL`, by default `ggml-base.bin` (multilingual, about 148 MB).
  The image does not bundle it.
  The compose service downloads it once into a volume from a pinned URL and checks a pinned sha256, or uses a file already there.
  Downloading weights is the only outbound traffic, and it carries no audio.
- Language is auto-detected unless `WHISPER_LANGUAGE` sets one.
- Transcription runs on a fixed pool of `LISTENER_THREADS` (default 4), one utterance at a time per worker, so a busy call queues rather than spreading over every core of a home server.
- Estimates to be measured in phase 1, not yet measured: the base model on 4 x86 cores with AVX2 should transcribe a 10 s utterance in well under a second, and keep the listener under 1 GB resident.
  Phase 1 is accepted only with a measurement on the owner's server class of machine: segment latency p95 under 5 s after the speaker stops, with four people talking in turn.

### How the server and the listener talk

The server is the client.
It opens a WebSocket to `SLIMM_LISTENER_URL` at `/v1/control`, with `Authorization: Bearer <SLIMM_LISTENER_SECRET>`, and keeps it open with backoff from 1 s to 30 s.
So the listener has no route into the server, and the server gains no route a module, a member or the listener could call to inject text.
The URL is checked with the existing `sidecar_url::validate` rules (plain `ws://` only for a loopback or private address), extended to the `ws` and `wss` schemes.

The protocol is `listener/1`, JSON text frames, with every message carrying `"v": 1`:

| Direction | Message | Fields |
| --- | --- | --- |
| listener to server | `ready` | `version`, `engine` (`whisper.cpp`), `model`, `max_sessions` |
| server to listener | `start` | `session`, `livekit_url`, `token`, `include` (identities), `language` |
| server to listener | `include` | `session`, `include` (the whole set, not a delta) |
| server to listener | `stop` | `session` |
| listener to server | `started` | `session` |
| listener to server | `segment` | `session`, `identity`, `start_ms`, `end_ms` (since session start), `text`, `language` |
| listener to server | `ended` | `session`, `reason` (`overload`, `room_error`, `time_limit`) |

The include set is sent whole so a lost or reordered frame can never leave someone included.
The server also drops any `segment` whose identity is not in the include set it last sent, so consent is checked on both sides.
A frame from a newer `v` closes the connection with a logged reason.

`SLIMM_LISTENER_LIVEKIT_URL` sets the LiveKit address the listener dials, defaulting to the server's own LiveKit URL.
On a deployment like prod, where the public LiveKit hostname goes through a proxy, the operator points it at the LAN address.

### Alternatives considered

| Option | Why not |
| --- | --- |
| The server joins the room itself with the LiveKit Rust SDK | libwebrtc in the server breaks the static musl build and the 20 MiB image gate, and a crash in native media code would take down chat. The listener isolates both. |
| LiveKit egress, track egress to a WebSocket | It can send a track as raw `pcm_s16le` over a WebSocket, but it is a separate service that needs Redis shared with `livekit-server`, and neither is deployed. It is one egress job per speaker, and it would still need a transcriber somewhere. A self-host would gain two services to get what the listener does in one. |
| Each client transcribes its own microphone | Strong on privacy, but it needs a different engine per platform (and the browser's built-in one sends audio to a cloud), costs phone battery, and can never give a module audio later. Kept as a note, not a path. |
| The LiveKit Agents framework (Python) | Built around cloud speech and LLM plugins and its own dispatch. The consent rules here need narrow control over exactly which tracks are subscribed, which is a small amount of our own code. |
| The listener in Python, reusing `slim-bots` | The SDK core is the same. A Rust crate in this repository shares the protocol fixtures and CI with the server, and keeps an operator component out of the bots framework. |

### Costs

- One more optional container, its model volume, CPU while a session is on, and nothing while none is.
- Each included speaker is one Opus audio subscription on the SFU, a few tens of kilobits a second, local to the host.
- Build: libwebrtc is downloaded prebuilt by the SDK's build script, for glibc, so the listener image is Debian-based and its own CI job carries that download.
  The server's build is unchanged.

## Consent

### Installing: the `call.audio` power

A module that wants call text declares the capability and a `call_audio` block:

```json
"addon_api": 4,
"capabilities": ["call.audio", "data.store", "schedule"],
"call_audio": {
  "purpose": "Writes down what is said in the call and posts the transcript when the call ends.",
  "keeps": "The transcript text, in this module's own data, for 30 days unless an admin changes it.",
  "permission": "start"
}
```

- `purpose` and `keeps` are required, plain text, 20 to 240 characters each.
  They are shown word for word at install, in the module's page, and to every person in a call before they agree.
  The host cannot verify them; it can only make sure everyone reads them, and the consent text says they are the module's own words.
- `permission` optionally names one of the module's own declared permissions (0021) that a member needs to start a session.
  With none, anyone in the call may ask.
- The install sheet shows it first, with the strongest tone the sheet has, as: label "Hear voice calls", description "Turns speech in calls into text for this module.", warning "Can hear voice calls in the channels you choose and turn what people say into text it keeps. Everyone in a call is asked first."
- The "I understand what this module can do" tick is required whenever `call.audio` is requested, verified module or not.
  This departs from 0067, where a verified module's Install press is the acknowledgement, because this power reaches people other than the admin.
- Approval never survives a new build, and is asked again when `purpose`, `keeps` or `permission` changes.

### Choosing channels

An approved module hears nothing until an admin picks voice channels for it, on a "Calls it can hear" card on the module's Dock page.
The list starts empty.
Direct message calls and group DM calls can never be picked.
A channel the module's principal cannot `VIEW_CHANNEL` is refused, so the existing channel permissions stay the outer bound.
Each change writes an admin audit row (owner decision 2026-10-17: every admin change is audited).

### Per call

A session is one module hearing one call.
Phase 1 allows one session per call.

1. **Asking.** A person in the call presses "Turn on <module>" and confirms.
   Their press is their own yes.
   Everyone else in the call is asked, at once, with the module's name, its `purpose` and `keeps`, who asked, and two choices: Allow and Not now.
2. **Starting.** It turns on only when every person in the call has said yes.
   If anyone says Not now, or 60 seconds pass without every answer, it does not start, and everyone sees which of the two happened, never who.
   While it waits, nothing is subscribed.
3. **While it is on,** everyone in the call sees a status banner naming the module, with Stop.
   Anyone in the call may press Stop, and it stops for everyone.
4. **Someone joins.** A joiner is asked before their audio is included and is excluded until they say yes: they are not in the include set, so the listener never subscribes to their track.
   Their banner says their voice is not included and offers Allow.
   If they choose Not now, the session stops for everyone, since it may run only while everyone in the call agrees.
   If they do not answer, they stay excluded and the session goes on.
   Closing the prompt (Escape) leaves them excluded with Allow still on the banner.
5. **Someone leaves.** They leave the include set.
   When no person is left, the session stops.
6. **Bots** are not asked and never heard: their tracks are never subscribed.
   A bot that plays music is not a person speaking.
7. **Hidden presence.** A member whose presence is hidden is asked like anyone else, and the prompt adds that the module will see that they were in the call.
8. **Members not in the call** see nothing in phase 1.
   Phase 2 marks the voice channel row, so someone deciding whether to join knows before they do.

Nothing about who said yes or no is stored or sent to the module.
The module learns who is included, because it has to attribute text, and that is all.

### Starting rules

- The caller is in the call by LiveKit's own account (`RoomLiveState`), the channel is armed for the module, the module is enabled with `call.audio` approved, and the caller holds the module's `permission` if it names one.
- The listener is connected and below its `max_sessions`.
- After a call where a request was declined, timed out or stopped, a new request in that channel waits 60 seconds, so a prompt cannot be used to badger people.
- Requests use the `Write` rate-limit class.

## What core keeps

Nothing that outlives the process.
The session (module, who asked, each person's answer, start time, segment count) lives in a map in memory, like `RoomLiveState`.
A restart ends every session: the listener sees its control connection drop and leaves the room, and clients find no session when they reload state.
Admin changes to the channel list are audited, like every admin change.
Segment text passes through the server's memory on its way to the module's queue and is never written to the database, the hub or the logs.
It is enqueued straight to the one module, never published on the hub, so no websocket subscriber can be sent it by a future change to a frame.

## Limits

| Limit | Value | When it is hit |
| --- | --- | --- |
| Channels | Admin-picked voice channels per module, never DMs | A request in any other channel is refused. |
| Sessions per call | 1 | A second request is refused while one is on. |
| Sessions per deployment | The listener's `max_sessions`, default 2 | A request is refused with "busy", and nothing is asked. |
| People included per session | 25 | Later joiners are not asked and stay excluded, and the banner says so. |
| Session length | 4 hours | It stops with reason `time_limit` and can be started again. |
| Utterance length | 15 s of audio | It is cut and the rest becomes the next utterance. |
| Segment text | 1,000 characters | Longer text is cut at a word boundary. |
| Segments per session | 120 a minute | Past that the server drops segments and counts them. |
| Transcriber backlog | 30 s of untranscribed speech | The oldest utterance is dropped and counted. |
| Sustained overload | Backlog full for 120 s | The listener ends the session with `overload`. |
| Answer window | 60 s | The request lapses. |
| Retry after a decline | 60 s per channel | A request is refused. |
| Fuel, memory, wall | The module's own manifest limits, on the background lane | As for any event run. |
| Module failures | The 0091 breaker, 5 in a row | The module is turned off, and its sessions stop with `module_disabled`. |

Segments go through the module's existing event queue (256 deep, oldest dropped).
`call.audio.stopped` carries `segments_sent`, the number the host enqueued, so a module can tell when it missed some.

## The module API

### Add-on API 4

`ADDON_API` becomes 4: level 4 adds `call.audio`.
A module declaring `call.audio` must declare `"addon_api": 4` or higher, and a server at 3 refuses it with "update the server", per 0100.
The events below are new event names inside the `event/1` envelope, which is additive.
`docs/modules/api-changelog.md` records level 4.

### Events

`call.audio` approved means the module is sent these four events for its own sessions.
They need no `subscriptions` entry and do not count toward its 8.

| Event | `data` fields |
| --- | --- |
| `call.audio.started` | `session_id`, `channel_id`, `started_at_ms`, `included` (user ids) |
| `call.audio.participant` | `session_id`, `channel_id`, `user_id`, `included` (bool) |
| `call.audio.segment` | `session_id`, `channel_id`, `segment_id`, `user_id`, `start_ms`, `end_ms`, `text`, `language` |
| `call.audio.stopped` | `session_id`, `channel_id`, `stopped_at_ms`, `reason`, `segments_sent` |

- `start_ms` and `end_ms` are wall-clock milliseconds, made from the session's start and the listener's offsets.
- `reason` is one of `stopped`, `declined`, `call_ended`, `time_limit`, `overload`, `module_disabled`, `channel_removed`, `listener_unavailable`.
  It never names a person.
- Event ids are `call-audio:<session_id>:<n>`, minted once, never redelivered.
- After a server restart no `stopped` arrives for a session that was on.
  A module treats a session with no event for 10 minutes as ended.
- The run's `caller.id` is the module's principal, as for every event.

### Host calls

None in phase 1: a module only listens.
Phase 2 adds a `call.audio` host call with `status` (is a session on in a channel, and who is included) and `request` (ask the people in a call to turn the module on, which only shows them the same prompt and can never start anything by itself).

### Client wire

| Route | Who | Does |
| --- | --- | --- |
| `GET /channels/{channel_id}/voice/call-audio` | `VIEW_CHANNEL` and `CONNECT` | The session, if any (`module_id`, `module_name`, `purpose`, `keeps`, `status`: `asking` or `on`, `asked_by`, `included`, `pending`, `expires_at_ms`), and the modules this caller may start here. |
| `POST /channels/{channel_id}/voice/call-audio` | In the call | `{module_id}`: ask. |
| `PUT /channels/{channel_id}/voice/call-audio/consent` | In the call | `{allow}`: answer. |
| `DELETE /channels/{channel_id}/voice/call-audio` | In the call | Stop, for everyone. |
| `GET` and `PUT /space/dock/modules/{id}/call-audio-channels` | `MANAGE_SERVER` | `{channel_ids}`. |

A websocket frame `voice.call_audio` carries the same session state to everyone who can view the channel, on every change, and `null` when it ends.
It is authorized per subscriber like `voice.screen_share_changed`.

## Test strategy

- **The session rules** are a pure state machine (`call_audio/session.rs`) with a fake clock, tested on every transition: unanimous start, a no, a lapse, a joiner's yes, no and silence, leave to empty, stop, and that a pending or declined person is never in an include set.
- **A fake listener** in the server's integration support speaks `listener/1` over a real WebSocket, records every include set it is sent, and emits scripted segments.
  Server tests drive joins and leaves through signed LiveKit webhooks, as the voice tests already do, and assert what a fixture module receives through `@event`.
- **The listener** is tested behind two seams: a `RoomSource` that yields scripted per-identity PCM frames in place of LiveKit, and a `Transcriber` that returns canned text.
  Endpointing is tested on synthetic PCM (tone bursts, silence, noise floor changes).
- **One real check**: an opt-in listener test, run in the listener's CI job against `livekit-server --dev` in a container, publishes a WAV made by `scripts/lib/make_fake_voice.py` from a test participant and asserts that the listener receives frames from an included identity and none from an excluded one, with the `tiny.en` model.
- **Protocol fixtures**: JSON samples of every `listener/1` message live in `crates/slimm-listener/protocol/` and both the server and the listener parse them in tests, so the two sides cannot drift.
- **Browsers**: an end-to-end scenario with two browsers and the listener is phase 2, opt-in under `E2E_PAR_OPT_IN`.
- **The module** is tested in slim-addons with its fake host, like `xp`.

## Phasing

### Phase 1: one consented call to a transcript

The smallest slice that is useful end to end: an admin installs the transcript module and picks a channel, people in a call agree, the listener transcribes, and the transcript is posted when the call ends.

Server (`crates/slimm-server`):

- Migration `0170_module_call_audio_channels.sql` (the next free number on 2026-11-02; check again before committing): `module_call_audio_channels(module_id TEXT, channel_id TEXT, PRIMARY KEY (module_id, channel_id))`, rows removed with the module and with the channel.
  Run `scripts/lock-migrations.py` and regenerate `.sqlx`.
- `config.rs`: `listener_url`, `listener_secret` (required with the URL, at least 32 characters), `listener_livekit_url`.
- `call_audio/`: `mod.rs` (the service in `AppState`), `session.rs` (the pure state machine), `link.rs` (the WebSocket client, reconnect and `listener/1`), `protocol.rs`, `tests.rs`.
- `voice/token.rs`: a `hidden` field on `VideoGrant`, and a listener token minter.
- `http/voice/voice_webhook.rs`: tell the service about joins and leaves, and a test that a `listener-` identity is ignored there and by the roster.
- `http/voice/voice_call_audio.rs`: the four call routes.
- `http/module_call_audio.rs`: the channel list routes and the audit row.
- `http/dock/manifest/call_audio.rs`: parse and validate the `call_audio` block.
- `http/module_host.rs` and `http/dock/capabilities.rs`: `call.audio` in the grantable list, not a host call, re-asked on a new build or changed text.
- `module_runtime/contracts.rs`: `ADDON_API = 4`.
- `http/module_events/`: the four events in `wire.rs`, and a direct enqueue to one module that bypasses the hub.
- `hub/event.rs` and `http/ws/frames.rs`: the `voice.call_audio` frame.
- `schema/openapi.yaml`: the routes, the frame and the manifest block.
- Tests: `tests/call_audio.rs`, `tests/module_call_audio_events.rs`, `tests/support/fake_listener.rs`.

Listener (`crates/slimm-listener`, its own workspace, excluded from the root one):

- `main.rs`, `config.rs`, `control.rs` (the `/v1/control` endpoint and `/healthz`), `protocol.rs`, `session.rs`, `room.rs`, `endpoint.rs`, `stt.rs`, `backlog.rs`, and tests.
- `docker/listener.Dockerfile` (Debian slim, non-root, read-only root, model volume).
- `.github/workflows/listener-ci.yml` (path-gated: fmt, clippy, tests, the real-LiveKit test, image build) and an image job in `main-builds.yml`, each with a `docs/ci.md` row.
- `docker-compose.yml`: a `listener` service under a `listener` profile, plus `.env.example` and `deploy/README.md`.

Client (`client/packages`):

- `api`: `client_voice.dart` and `client_dock.dart` bindings, a `CallAudioState` model in `models_voice.dart`, the `voice.call_audio` frame in `events_frames.dart` and `events_parse.dart`, and `callAudio` on the manifest in `models_dock.dart`.
- `app`, settings: the `call.audio` entry in `dockHostCapabilities`, the always-required tick in `dock_install_consent.dart`, and `dock_call_audio_card.dart` (modelled on `dock_schedule_card.dart`; a `modalPage` section, rule 5 of `docs/design/desktop-vs-mobile.md`).
- `app`, voice: `providers/call_audio.dart` (route plus frame); `widgets/call_audio_start.dart`, a control beside the call controls that confirms with `showAppSheet` (rule 4); `widgets/call_audio_prompt.dart`, the ask, as a full-focus overlay modelled on `incoming_call_overlay.dart` (rule 7); `widgets/call_audio_banner.dart`, the status banner with Stop or Allow, modelled on `local_screen_share_banner.dart` (rule 6).
  Lucide `audio-lines` marks it.
- Widget tests by key for each, and a provider test.

Docs: a "Call audio" section in `docs/modules/reactive-modules.md`, the level 4 entry in `docs/modules/api-changelog.md`, and an operator section in `deploy/README.md` on the model, CPU and the LAN LiveKit address.

slim-addons: `modules/transcript` 0.1.0, below.

### Later phases, listed and not built

2. **Reach and hardening.** The voice channel row shows when a module is listening; a personal "never ask me" setting that answers Not now; the `call.audio` host call (`status`, `request`); an admin "ask when a call starts" channel option; the server also drives the listener's subscriptions through the room service, as a second guard beside the listener's own filter; the two-browser end-to-end scenario.
3. **Live captions.** A call slot in the 0090 surface vocabulary, so a module can show captions in the call while it is on, and more than one module per session.
4. **`speech.transcribe`.** A host call for audio a module already holds, such as a voice message, on the same transcriber.
5. **Raw audio for connectors.** When host-run connectors exist (0090 phase 3), a connector with `call.audio` can receive per-speaker PCM from the listener over the same consent, for recording or its own processing.
   Core still stores none of it.
6. **GPU transcription.** A listener image built with whisper.cpp's GPU backends.

## The first consumer: the transcript module

`modules/transcript` in slim-addons, add-on API 4, written in Rust like `xp` and tested with its fake host.

- Capabilities: `call.audio`, `data.store`, and `schedule` (a daily prune, which also gives it the posting channel the admin chooses).
- Data: a `sessions` table (session id, channel id, started, stopped, reason, segments sent and received) and a `segments` table (session id, `user_id` declared `"member": true` so account deletion purges it (0100), start, end, text).
- On `call.audio.segment` it inserts one row.
  On `call.audio.stopped` it posts the transcript in time order as itself to its posting channel, as many messages as the length limit needs, naming each speaker, and noting when `segments_sent` is more than it received.
- Settings: `keep_days` (default 30), `post_when_done` (default on).
- Its `purpose` and `keeps` are the example above.
- Speech-to-text does not run in the module: the listener on the server's host runs whisper.cpp, and the module only receives text.

## Phase 1 as built

Where the build differs from, or adds to, the design above.

- The `voice.call_audio` frame is carried by the hub's durable channel, not the ephemeral one.
  It has no `seq` and is never stored, but a missed `null` would leave a banner on for a session that ended, which the ephemeral channel's drop-on-lag would allow.
  A client also reads the route again after a reconnect.
- The frame carries an `ended` word beside a `null` state (`declined`, `lapsed`, `stopped`, ...), so people see whether an ask was refused or lapsed.
  A module is still told `declined` for both, and never who.
- Hidden-presence members are left out of `included` and `pending` for every viewer but themselves, as the call roster does.
- The server pings the listener every 2 s, and the listener treats 5 quiet seconds as a lost connection.
- The listener's token comes from the server's `VoiceService`, with a `hidden` grant added.
- Measured on the owner's machine (Ryzen 9 9950X3D, release build, base model, 4 workers): four speakers in turn, 7 s of speech each, text arrived 2.6 s after the speaker stopped at the 95th percentile (600 ms of that is the endpointer waiting for silence), and the process peaked at 582 MB resident.
- The transcript module also asks for `message.post`, since posting as itself needs it, and runs its timer every 15 minutes so a silent call is posted soon.

## Open questions for the owner

Each has the default this record takes until he says otherwise.

1. Should `call.audio` need the explicit tick even for a verified slim-addons module, departing from 0067?
   Default: yes, always.
2. When someone who joins a running session chooses Not now, should it stop for everyone, or go on without them?
   Default: stop for everyone.
3. Should a session start only when everyone in the call answers yes, or start for whoever has said yes and leave the rest excluded?
   Default: everyone, within 60 seconds.
4. Is downloading the whisper model once from its public host at first start acceptable, or should the image bundle it (about 150 MB larger)?
   Default: download once, pinned by sha256, into a volume.
5. Should the listener run on prod once built?
   Default: not until phase 1's CPU and latency measurement is in and he says so.

## Not decided here

- Captions in the call UI, beyond the phase 3 slot.
- What a connector may do with raw audio, which is decided with connectors.
- Translation.

# Internals

How and why individual modules work the way they do, moved out of their doc comments so the code keeps a short why.
Each section names its file; decision records in `decisions/` hold the choices themselves.

## Upload content types

`crates/slimm-server/src/media/content_type.rs`

The upload content-type allowlist: which label an attachment is stored under, decided from the bytes alone, and whether that type is safe to render inline in a browser.

An attachment matching none of it is still accepted, as [`GENERIC_BINARY`]: a forced download that no browser is ever asked to render, exactly as inert as the zip and `text/plain` entries below.
Only avatars, icons, emoji and other pictures require a match.

Never derived from a filename extension or a client-declared Content-Type header: both are attacker-controlled input, and trusting either is what would turn this into a stored-XSS vector (a client claiming `image/png` or naming a file `photo.png` cannot talk its way into being served as `text/html` or `image/svg+xml` by any means, because neither is ever checked - only the bytes are, against a fixed allowlist that contains neither).

### The `text/plain` fallback, and why it is safe to add

Source files, logs, csv, json and yaml have no magic bytes at all, so the only way to admit them is a last-resort heuristic tried after every real signature has failed to match: valid UTF-8, and every character is either tab, newline, carriage return, or not a Unicode control character (which also excludes NUL, since NUL is itself a control character).
This is deliberately loose - it is a filter for "plausibly readable text", not a format detector - and three things follow from that looseness, each checked rather than assumed.

An HTML or SVG file is entirely printable ASCII/UTF-8 text and passes this check, so it is stored and later served as `text/plain`.
That is inert: `is_inline` never marks `text/plain` inline, so `serve` (`http/attachments.rs`) always sends `Content-Disposition: attachment` for it, which forces a save-file dialog in every browser tested rather than a render, and `X-Content-Type-Options: nosniff` on top means the browser is additionally forbidden from second-guessing the declared type and rendering it anyway.
Confirmed by tracing the real handler, not assumed: `serve` derives `disposition_kind` from `is_inline(content_type)` with no branch that could make `text/plain` inline, and `nosniff` is set unconditionally on every response the function builds.

A UTF-16 file (or any binary that happens to contain only printable ASCII) can be misclassified.
Checked against the real sniffer rather than assumed, and one genuine surprise came out of that check: BOM-less UTF-16 text (either endianness) is refused outright, since the NUL byte every ASCII-range code unit carries is a control character this scan does not admit, and a UTF-16BE BOM (`\xFE\xFF`) is refused the same way because it is not valid UTF-8 at all.
A UTF-16LE BOM (`\xFF\xFE`) is the one real collision, and it is not with this check: those same two bytes also satisfy `is_mp3`'s frame-sync heuristic below, so a UTF-16LE file is stored as `audio/mpeg` rather than `text/plain` - a wrong label, not a hole, since `audio/mpeg` is exactly as inert a forced download as `text/plain` is.

**This residual is real, not just theoretical, even after `is_mp3` was tightened to validate the frame header's reserved fields rather than trusting the sync bits alone (see `is_valid_mpeg_frame_header`).** Checked, not assumed: the BOM itself fixes the header's version and layer fields to non-reserved MPEG1/Layer-I values regardless of file content (`0xFE`'s own bits decode that way), so the tightened check's only remaining power over a UTF-16LE file rests entirely on the first content byte's bitrate and sampling-rate bits.
Measured over all 256 byte values, 180 (about 70%) still pass; over printable ASCII specifically, 72 of 95 still pass.
So most real UTF-16LE text - `[0xFF, 0xFE, b'h', 0, b'i', 0]` among them - still sniffs as `audio/mpeg`, not `text/plain`, after this change.
The tightening is a real improvement against arbitrary binary; it does not close this specific collision, and that is stated here rather than left to be rediscovered.

A binary format that never happens to emit a NUL or a control byte is the remaining general gap, and the failure mode is the same as above: a wrong label on a forced download, never rendering or execution, so it is accepted rather than chased.

Whether admitting this fallback turns the allowlist into "almost anything" in practice: yes, for the specific class of bytes that are valid, mostly-printable UTF-8, and that is the point - it is exactly the reference-material class the owner asked to widen, and the type it maps everything in that class to (`text/plain`, forced download) has no rendering surface for any of it to exploit.
The allowlist is still a real boundary against everything outside that class: arbitrary binary, and anything carrying a control byte a text editor would not expect.

### Video and audio are never inline

The client has no player and falls through to a download tile for anything outside its own explicit inline-image list (`inlineImageTypes` in `attachment_view.dart`), so marking a video or audio type inline here would only widen what a browser is asked to render, for no client-visible benefit.
Revisit once the client actually has a player.

### docx/xlsx/odt are zip containers too, and are not disambiguated

Telling an Office or OpenDocument file apart from a plain zip needs reading the archive's central directory for a marker entry, and a zip served as a forced download with `nosniff` has no rendering surface either way, whatever the original file actually was - so all of them are simply `application/zip`.

## WebSocket memory admission

`crates/slimm-server/src/hub/memory_guard.rs`

Admission control for memory: refuses a new WebSocket connection when the process is close to its cgroup memory ceiling, the same way [`super::Hub`] already refuses one once its own connection ceiling is reached.
This only ever gates admission of a *new* connection; nothing here touches one already open.

A capacity study found no equivalent protection for memory: holding 1024 connections costs about 164 MB, but the process was OOM-killed by the kernel in under a second at a 144 MB cgroup ceiling, after silently accepting 879-976 connections it could not afford.
Every send afterwards failed with connection refused and nothing was delivered.
This guard closes that gap.

### Discovering the limit

Cgroup v2 (`memory.max`, `memory.current`, `memory.stat`, directly under `/sys/fs/cgroup` inside a cgroup namespace - verified on the production host) is tried first, since that is what Docker sets and what the kernel actually enforces.
Cgroup v1 (`/sys/fs/cgroup/memory/memory.limit_in_bytes` and friends) is a fallback for older hosts.
`SLIMM_MEMORY_LIMIT_BYTES` overrides the discovered limit outright, for a deployment where the cgroup is not visible to this process.
If no limit is discoverable by either means, [`MemoryGuard::admit`] always admits: a bare-metal self-host with no configured ceiling behaves exactly as it did before this guard existed.

### Choosing the usage signal

`memory.current` includes page cache, most of which the kernel reclaims for free under pressure; comparing it against the limit directly would refuse connections on a server that has simply read a lot of database pages.
The readily reclaimable part of that cache is `inactive_file` in `memory.stat`, so this guard uses `memory.current - inactive_file` rather than raw `memory.current`, and deliberately not the narrower `anon` field: a WebSocket connection's steady cost is mostly kernel socket buffer memory, which `memory.current` counts but `anon` does not, so `anon` alone would undercount the exact load this guard exists to police.
Active file pages and other kernel memory the kernel does not reclaim on demand both stay counted, which is the conservative direction to be wrong in.

### Choosing the reserve

A connection costs about 144 KB, measured linearly from 100 to 1024 open sockets.
The runs that got OOM-killed died within a second of the ramp starting, meaning hundreds of connections can be admitted between one memory reading and the next before a guard that only checks "is there room for one more" would even notice - so the reserve has to cover a burst of admissions across a reading's lifetime, not just a single connection. 256 connections' worth (256 * 144 KB ~= 36 MB) plus a margin for ordinary request working memory that is not WebSocket-specific (message bodies, permission cache growth, attachment buffers) rounds up to 64 MiB.

### Caching

Reading `memory.current` and `memory.stat` on every connection attempt is correct but wasteful under a connection storm - the exact scenario this guard exists for.
Readings are cached for a few hundred milliseconds, bounding staleness to a fraction of a second while capping the read rate to a handful per second regardless of how fast connections arrive.

## Code runner broker

`crates/slimm-server/src/code_runner.rs`

The code-runner broker: this server's half of running a fenced code block through a self-hosted Piston instance (`engineer-man/piston`).

**slim-m builds no runner of its own and executes nothing itself.** This module speaks Piston's own existing `POST /api/v2/execute` and `GET /api/v2/runtimes` protocol exactly (see [`piston`]) rather than inventing a parallel one - the operator points `SLIMM_CODE_RUNNER_URL` at a Piston instance they run and trust, the same relationship this project already has with the push relay and a self-hosted LiveKit.

[`CodeRunner`] is the same first-class two-state shape `push::PushSender` models for the push relay: `SLIMM_CODE_RUNNER_URL` is optional, and absent is the default, fully supported state - a deployment that never sets it behaves exactly as it does today, with no Run affordance on any code block and nothing resembling a startup error.

**The server brokers and never executes.** Every call this file makes carries exactly the block that triggered it - a language name and the code - and nothing else: no token, no session, no way for the runner to call back into this deployment.
Whatever a compromised or misbehaving runner does, the worst it can produce is a wrong answer in the block that asked for it (see docs/decisions/0007's sharpest-edged constraint).

**Ceilings are the server's, not Piston's.** Piston already implements real sandboxing - no network access by default, an unprivileged user and Linux namespaces per submission, CPU/wall-time and memory caps, output truncation, SIGKILL on misbehaviour - and this file does not reimplement any of it.
What it adds on top: an explicit `run_timeout`/`compile_timeout` and memory ceiling on every request rather than trusting Piston's own defaults or however an operator's instance happens to be configured ([`piston::execute`]), an outer HTTP client timeout ([`CLIENT_TIMEOUT`]) so a runner that never answers at all cannot hang the request that asked for it, and a hard cap on how much of a response this server will ever read ([`piston::MAX_RESPONSE_BYTES`]), refusing rather than absorbing anything past it - the same style `http::canvas_write::MAX_PROPS_BYTES` already uses.
`Class::CodeRunner` (`crate::ratelimit::class::Class`) is the matching rate-limit ceiling, charged once per actual invocation (`http::module_commands::execute_code_runner`).

**Trusting the operator, not the code.** Running arbitrary code from whoever can type in a channel is a real risk regardless of how well Piston sandboxes it; that is why the permission bit this ships with (`Permissions::RUN_CODE`) defaults to nobody and why reaching this at all needs configuration an operator adds deliberately, never something a deployment gets by default.
An operator who enables it is trusting the people in their own space, the same trust every other write permission in this project already rests on - and it is worth saying plainly rather than dressing this up as more exotic than it is.

**Which languages** a deployment can offer is read from the runner itself ([`CodeRunner::languages`], `GET /api/v2/runtimes`) rather than kept as a list in this codebase, so a client is never offered a Run button for a language nothing has confirmed is actually installed on this specific instance - see PR #1211.

## WebSocket permission cache

`crates/slimm-server/src/http/ws/permission_cache.rs`

One connection's memory of which channels its viewer may see.

`authorize` asks `has_permission` once per delivered event, and that resolves to five queries (channel, two role queries, overwrites, timeout deny), six on a typing frame.
`MAX_CONNECTIONS` is 1024 against a read pool of 8 shared with the write path, so a busy channel spends most of the pool re-deriving an answer that changes far more rarely than messages arrive.

A whole [`Permissions`] set is cached rather than one bit.
`authorize` no longer asks one question: a frame can need a second bit beyond `VIEW_CHANNEL` (a live transcript line needs `VIEW_TRANSCRIPTS`), matching what its read route requires, so a member denied that bit by an overwrite is not handed over the socket what the route refuses them.
A canvas frame needs only `VIEW_CHANNEL`, since a member without `USE_CANVAS` spectates the canvas.
Caching the set costs nothing over caching the bit - `has_permission` is `permissions_in_channel().contains`, the same five queries - and an earlier version of this doc argued the opposite from a mechanism that is gone: what made a set risky was event-keyed invalidation, and the epoch below replaced that.
A set taken at epoch N is exactly as fresh as one bit taken at epoch N.

**The dangerous direction is one-way.** A stale `true` delivers an event to somebody whose view was just revoked; a stale `false` merely withholds one they will get on reconnect.
Two things bound it:

- **[`Hub::permissions_epoch`], which is what makes this correct.** An entry is only reused while the epoch it was taken at still stands, and the hub bumps that inside `publish`, before the send. So a revocation invalidates every connection's entries the moment the publishing request reaches its publish call, with no dependence on when - or in what order - any connection receives the event.

Keying on the events themselves was tried first and is wrong, which is worth recording because it looks right.
Delivery order across concurrent writers is best-effort (`hub.rs`'s own module doc says so), so a connection can be handed a `message.created` from one request before the `overwrite.changed` from another that had already committed.
Invalidating as each event arrives leaves the pre-revocation answer serving that message, and every other one that wins the same race.

- **[`TTL`], as the outer backstop.** The epoch only moves for events that are published; it says nothing about a route that writes permissions and publishes nothing, which is the failure this codebase actually had - the 2026-07-30 audit found `roles.rs`, `overwrites.rs` and `channels.rs` publishing nothing at all, and invite redemption still grants a role with no event. Expiry turns "a permanent leak" into "at most [`TTL`] of one".

The residual is the gap between a handler's commit and its `publish` call.
No handler that publishes a permission event has an await between the two, so it is a few instructions with nothing scheduled in between, rather than a window another task can be woken inside.

An error is deliberately never cached: a transient read failure fails closed for its own event and leaves nothing behind, so one blip cannot silence a channel for the rest of the window.

## Unique canvas op timestamps

`crates/slimm-server/src/store/canvas/canvas_op_clock.rs`

A per-op timestamp, unlike plain `now_ms()`, guaranteed never to repeat for as long as this `Store` exists.

`canvas_objects.deleted_at` doubles as the fence `restore_candidates`'s `clear` branch matches a whole batch of un-delete candidates against (`WHERE deleted_at = target.created_at`), on the stated assumption that "the single writer this database has means no other write can share that millisecond." That conflates strict ordering with distinct values: two sequential `submit_canvas_op` calls can read the same wall-clock millisecond from `SystemTime::now()`, which is well within reach on a fast SQLite/WAL commit.
A `remove` and an unrelated `clear` sharing one timestamp would let restoring the `clear` silently un-delete whatever the `remove` touched too - even a member's own removal of their own object, with no `MANAGE_CANVAS` involved in that removal at all.

Every canvas-op write already runs inside `Store::begin_write`'s exclusive `BEGIN IMMEDIATE` lock, so calls into this function are already totally ordered within one process's lifetime; the in-memory counter alone only has to break a tie between two reads of the same millisecond, not coordinate concurrency none of these calls can have.

A bare in-memory counter resets to zero on every process restart, though, and a burst of concurrent submissions just before a crash can have pushed it several milliseconds ahead of the wall clock; if the process restarts fast enough for real time to still be inside that window, the first post-restart call could return a value a still-live, un-restored fence already depends on being unique.
Seeding the counter from `MAX(created_at)` already committed to `canvas_ops`, once per `Store` (so once per process, since a restart constructs a fresh `Store` rather than reusing one that outlived it), closes that: the seed is read inside the caller's own write-locked transaction, so no call on this `Store` can race ahead of it, and the database itself cannot move backward across a restart the way an in-memory counter does.
This does not, and cannot, protect two separate processes writing the same database file at once - each would seed and then advance its own counter independently - but nothing in this project's single-process architecture is meant to allow that in the first place.

The seed query names every kind explicitly rather than a bare `SELECT MAX(created_at)`: over a `canvas_ops` growing without bound (`move`/`reorder` rows are never swept, see `canvas_ops_sweep.rs`'s own module doc), an unfiltered `MAX` cannot use an index at all and pays for a full table scan under this same write lock.
Matching the `canvas_op_kind` CHECK constraint's own list against the `canvas_ops_kind_created_at` index turns that into one index descent per kind - a handful of steps regardless of table size, the same optimization that also makes the sweep's own per-kind queries cheap.

## Voice routes

`crates/slimm-server/src/http/voice.rs`

Joining a channel's voice room, and seeing who else already has.

Most of these routes are almost entirely the check in front: the token this hands back is a bearer credential the SFU trusts, so what a caller may do in a room is decided here, once, from their permissions in that channel.

Eviction is the other half of that.
A minted token cannot be revoked, so its TTL bounds how long a removed participant could walk back in; removing them from the room is what makes a kick take effect now rather than in two minutes.

The roster is read-only: `VIEW_CHANNEL` is the gate, the same bit that lets a member read a text channel's messages without also being able to send into it.
A participant who chose to appear offline is dropped from every viewer's roster but their own, the same treatment [`crate::presence`] gives every other surface; see [`roster`]'s doc comment for why that is a deliberate call rather than an oversight.

The heartbeat pair is the exception to "the check in front": `heartbeat` is gated the same way minting a token is, but `forget_heartbeat` is not gated at all beyond authentication, because forgetting a caller's own liveness marker exposes nothing about the channel it names.

The heartbeat pair is also where [`Event::VoiceActivityChanged`] is published: on the first heartbeat for a `(user, channel)` pair (a join) and on a real forget (a clean hangup), each a single lock-held check-and-write against [`crate::voice::VoiceService::record_heartbeat_reporting_new`] / [`crate::voice::VoiceService::forget_heartbeat_reporting_removed`] so a routine refresh never republishes and two concurrent first heartbeats cannot both publish either.
The third publish site, the stale-heartbeat sweep, lives in `lib.rs` rather than here.
The mute and deafen reports (`voice_self_state.rs`) publish it too, for a caller with a call on record, so a roster read from outside the call shows who is muted; the SFU carries the mute itself, on the caller's own track, and `is_muted` in the roster is read from there.
The first heartbeat and both reports drop the cached roster before they publish, so the re-read they prompt is never answered from before them; a report from a caller with no call on record still drops it, and tells nobody.
A microphone track's `track_published` or `track_unpublished` webhook publishes it as well, since that flips `is_muted` with no mute report.
A mute report waits up to 2 s for the SFU to show the reported state before it publishes, because the mute travels the signal websocket and can land after the report.
The sweep asks the SFU before it evicts: a member whose heartbeat went stale is kept while LiveKit still reports them `ACTIVE`, up to three times the stale threshold, because heartbeats travel the API path and that can break while the call's media is fine.

## Voice heartbeat and answering a ring

`crates/slimm-server/src/http/voice.rs`

Refreshes proof that the caller is still on this channel's call.

`CONNECT` is the gate, the same one minting a token requires: a heartbeat for a room the caller could not have joined is not evidence of anything.
Best-effort by design on the client, and idempotent here - repeating it only pushes the deadline out further.
See [`crate::voice::VoiceService`] for what a heartbeat that stops arriving eventually causes.

Publishes [`Event::VoiceActivityChanged`] only on a first heartbeat for this `(user, channel)` pair - a real join - never on the routine refreshes that follow it every few seconds for as long as the call lasts.

A FIRST join is also what answers an outstanding [`crate::voice::CallRings`] ring naming this caller as the callee, since nothing separate marks answering: joining a call *is* answering it.
A later keepalive from someone already in the room answers nothing.
See `voice::ring`'s own module doc for why answering has no route of its own.

The ring is claimed BEFORE the heartbeat is recorded, and the ordering is load-bearing rather than incidental.
`CallRings` and `CallHeartbeats` are separately locked, so with the record first there was a window - a few milliseconds against a 30-second timeout - in which [`crate::sweep_stale_call_rings_at`] could take the ring between the two.
The callee ended up genuinely joined while the server published `TimedOut` and evicted the CALLER, leaving one person alone in a room with no `Answered` event ever sent.
Claiming first makes the two outcomes exclusive: either this takes the ring and the sweep finds nothing, or the sweep took it first and this reads as an ordinary join, which is exactly what it is by then.

[`crate::voice::VoiceService::has_heartbeat`] gates that claim, and it is not redundant with the ordering above.
Moving the claim ahead of the record also moved it out from behind `is_a_real_join`, so without this gate EVERY heartbeat would try to answer - including the routine 15-second keepalives a call sends for as long as it lasts.
A caller hanging up and immediately calling back, while the callee is still sitting in the room, would then have that second ring answered by the callee's own background timer within 15 seconds, with the callee never seeing or touching it - and an explicit Decline would be racing their own keepalive to the lock.

The read-then-write that gate opens is the one [`crate::voice::VoiceService::has_heartbeat`]'s own doc warns about, but it is harmless here: it decides only whether to ATTEMPT the claim, and `CallRings::answer` is itself atomic, so two concurrent first heartbeats can both attempt and exactly one can win.
The publish that genuinely needs the single lock-held check still uses `record_heartbeat_reporting_new`, untouched.

## Module host and ABI v1

`crates/slimm-server/src/module_runtime/mod.rs`

The module host: runs an installed module's wasm artifact under strict resource limits, per docs/decisions/0021-modules-and-the-dock.md's Phase 3.
This is the one place in slim that executes module code; everything above it (`http::module_commands`) only decides *whether* a call may reach here, never what a module does once it has.

## Module ABI v1

A module is a wasm binary that exports exactly two functions and one memory, and imports nothing at all - see [`ModuleHost::run`] for why a single import of any kind is refused outright rather than sandboxed.

- `memory` (exported linear memory). - `alloc(len: i32) -> i32`: reserves `len` bytes inside the module's own memory and returns a pointer to them. Called once by the host, before `run`, to get somewhere to write the request. - `run(in_ptr: i32, in_len: i32) -> i64`: given the request the host just wrote at `in_ptr`/`in_len`, returns a packed `(out_ptr << 32) | out_len` pointing at the response, written wherever the module likes (its own static data, a second `alloc`, or the input region reused in place).

The host writes a UTF-8 JSON request into the memory `alloc` returned, calls `run`, and reads `out_len` bytes at `out_ptr` back as a UTF-8 JSON response.
What that JSON looks like is a contract between `http::module_commands` and the module, not this host: see that module's own doc for the `{command, input}` / `{ok, output}` / `{ok: false, error}` shapes.
[`ModuleHost::run`] itself only moves bytes; it has no opinion about what is inside them.

No imports means a module can only compute: it cannot touch the network, the filesystem, or anything else in the host process.
That is the entire v1 security model, and it is why every other capability a module might eventually want (posting a message, reading a key-value store) has to come later as an explicit, mediated host function rather than ambient access - see decision 0021's "no ambient authority" principle.

## The mediated-capability surface (decision 0023)

[`ModuleHost::run_with_capabilities`] is the seam for that "later": with a [`CapabilitySurface`] enabled, a module may import the single gated `slim.host_call` function (and nothing else), whose requests the surface gates and answers: the gate ([`capabilities`]), [`kv`]'s `kv.store` and [`post`]'s `message.post`.
A run is enabled only for a module an admin approved a host capability for; every other run passes [`CapabilitySurface::Disabled`] and behaves exactly as the import-free model above.
See [`capabilities`] for the gate and the fail-closed guarantees.

## Metrics endpoint

`crates/slimm-server/src/http/metrics.rs`

`GET /metrics`: process resident memory, request counts by rate-limit class, per-route request latency, SQLite pool occupancy, currently open WebSocket connections, the memory-admission guard's own view of its ceiling, usage and refusals (`crate::hub::memory_guard`), and whether the configured SFU answers - as Prometheus text exposition format.

Built to close the exact gap CLAUDE.md records: LiveKit crashlooped for half an hour behind a `voice enabled` line that only ever reports the server's own config, never whether the SFU it names actually answers.
`compose-smoke` now checks that by hand once, at deploy time; this makes it an ongoing, scrapable signal.

**Per-route latency** is recorded continuously by [`super::route_timing`], not sampled lazily the way `store/analytics.rs`'s memory time series is: a latency reading taken only when an admin happens to open a screen would answer for whatever request happened to be running at that moment, not for the traffic in between - useless for finding a slow route.
See that module's own doc for the cardinality reasoning behind labelling by route template rather than raw path.

**Auth**: gated on an authenticated session holding `MANAGE_SERVER`, the same bit `/space/analytics` already gates on, rather than left open the way `/version` is.
`/version` discloses a handful of deployment-wide facts an unauthenticated caller needs before an account exists; this discloses traffic volume by class and connection counts, which is a member-count-adjacent signal about a specific self-hosted community, not the kind of thing this project leaves unauthenticated.
There is no service-account or API-key concept in this server, so an admin's own session token is what a Prometheus scrape has to carry; a dedicated scrape credential is a reasonable follow-up if that friction turns out to matter, not built here.

**Rate limit**: `Class::Write`, not the generous `Class::AuthedRead` most authenticated GETs use, because `write_voice` below makes a real, uncached outbound call to the configured SFU on every scrape - a cheap list read this is not, and a scrape interval short enough to blow `Write`'s budget is already misconfigured against the SFU it is probing.

**No metrics crate.** `docs/dependencies.md` already declines a charting package for three bar charts on the grounds that a small, bespoke output is a function, not a dependency; four gauges and two counter families hand-rolled as text is smaller still, and a crate like `prometheus` or `metrics` would bring its own registry, encoder, and (for `metrics`) an exporter trait object this server has no other use for.

## Message search

`crates/slimm-server/src/http/search.rs`

Full-text search over messages, backed by the FTS5 index kept current by the triggers in migration 0002, plus a Slack-style operator layer over it: `from:`, `in:`, `has:`, `before:`/`after:`.

Two routes share every bit of this file beyond their own permission scoping: `GET /channels/{channelId}/messages/search` (the channel header's search panel) searches one channel, named in the path or by `in:`, and requires `VIEW_CHANNEL` on the path channel up front; `GET /search/messages` (the command palette's cross-channel scope) has no path channel to check and instead searches every channel [`crate::store::Store::visible_channels`] says the caller can view, or the subset of those named by `in:` when given.
Neither ever reaches a channel the caller cannot view: [`resolve_scope`] is the one place `in:` is resolved and permission-filtered for both, and the cross-channel route's default scope is `visible_channels` itself, which only ever returns channels `VIEW_CHANNEL` already grants.
`visible_channels` also excludes DMs and threads (see its own doc comment), so cross-channel search never reaches a DM the caller was not searching directly.

Plain words in `q` match as prefixes (`Win` finds `Windows` and `Win11_24H2.iso`): the tokenizer indexes that file name as `win11`, `24h2` and so on, and a typed `Win` is none of those whole.
A word of one character matches whole tokens only: there is no `prefix=` index, so `"w"*` would walk every term starting with `w` across all channels (0.06-0.18 s measured per letter, more on a large deployment).
A `q` that uses FTS5's mini query language (`AND`/`OR`/`NOT`, `"phrase"`, `NEAR(...)`, an explicit `*`) reaches FTS5 as written, and `uses_fts_syntax` is what tells the two apart.
That is safe against leaking another channel: the index has exactly one column (`content`), so a query string has no other column to pivot to, and the channel restriction is an ordinary SQL predicate the query text can never reach, never part of the `MATCH` expression itself.
See [`crate::store::Store::search_messages`] for the rest of that reasoning and for how a malformed query surfaces as [`SearchError::InvalidQuery`] rather than a 500: SQLite only validates FTS5 syntax once the statement runs.

The operators are parsed client-side (`message_search_query.dart`), which is why this file only ever sees them as already-split query parameters - `q` never carries `from:nick` as literal text a caller could exploit to widen a channel restriction the way `q` itself cannot.

Channel and member search need no route here at all: both are already answered from data the client already holds permission-correctly.
`GET /channels` only ever lists what [`crate::store::Store::visible_channels`] grants, so the client's local channel list is never wider than that; the member list (`GET /members`) is deployment-wide by design (see `http::users`'s own doc comment), not scoped to a channel, so there is no per-channel visibility question to get wrong there.
The command palette (`command_palette_items.dart`) filters both lists by name locally.

## Where secrets are stored on each platform

`client/packages/platform/lib/src/persistent_key_store.dart`

Persistent [KeyStore] backends.

iOS, Android, macOS and Windows all get the platform keychain (Keychain, Keystore, Keychain Services, and DPAPI-backed Credential Locker in turn) through flutter_secure_storage: none of those four backends depends on a background service that might not be running, so the OS itself guarantees one is always present, on a laptop exactly as on a phone.

Linux is the exception, even though flutter_secure_storage also ships a Linux backend: that backend talks to a Secret Service over D-Bus (gnome-keyring, kwallet plus ksecretsservice), and plenty of real sessions - a fresh install, a window manager with no keyring agent, a container - do not run one, so calls would fail unpredictably at runtime even on a machine where the build itself succeeds.

Transport-only security is the project's v1 scope (see docs/decisions/0001-owner-decisions.md); this file is the Linux key-storage tradeoff that follows from that, not itself a recorded decision: a session token and a push key are not payment credentials, so a file only this OS account can open is a proportionate, always-available choice for Linux rather than one that depends on a keyring agent nobody promised would be running.
It is weaker than a real keychain - no OS-enforced encryption at rest, and it does not resist another process already running as this same OS account - but it is not readable by a different account on a shared machine, which is the threat this Linux build actually faces today.

macOS and Windows used to sit on that same file, back when this reasoning was written for "desktop" as a whole rather than for Linux specifically.
Both ship a real OS-backed keychain with the same always-present guarantee as the phone platforms, so there is no longer a reason to leave them on the weaker fallback; [migrateLegacyFileSecretsIfNeeded] is the one-time move for an install that already has secrets sitting in that file from before this change.

The web build does use flutter_secure_storage, because its browser backend is the only storage a browser has: values are AES-GCM encrypted under a key that itself lives in `localStorage`, so this is obfuscation against a casual look, not secrecy against script running on the same origin.
It is also refused outright outside a secure context, so a plain-http LAN server gets no persisted session at all.
The web build exists to drive this UI automatically; it is not a distribution target, and nothing here should be read as a claim that a browser stores secrets as well as a phone does.

## Voice call generations

`VoiceController` bumps a call generation on every join and every leave, and each async step records the generation it started under.
A channel switch or a hang-up mid-join starts or ends a newer call on the same instance, so every write after an await first checks it is still current.
Without the check an abandoned join's belated failure landed as the current, different channel's error and hid a call that had actually connected (`voice_controller_join_race_test.dart`).

Leave is guarded the same way.
Tearing a session down is a round trip to the SFU and nothing in the UI waits on it, so someone who hangs up and taps a channel again straight away can have a newer call connected by the time the old leave resumes.
Everything after that point belongs to the newer call, so a superseded leave writes nothing: not the state reset, which left a live call with no channel id, and not the heartbeat forget, which the server turns into a hangup it broadcasts to everyone else.
The heartbeat entry the abandoned call leaves behind is what the server's staleness sweep (`voice/heartbeat.rs`) exists to collect.

The controller composes small collaborators for the rest of its surface: input settings, audio devices, participant volumes, camera hiding, video controls, screen share, rejoin, the SFU connect and the session-state sync.
Each takes a `VoiceStateAccess` rather than the controller, and the controller exposes them as `input`, `devices`, `volumes`, `cameras`, `video` and `share`.

## What a call that comes back keeps

A join into the channel the call is already in is the same call coming back: the automatic rejoin after a drop, "Try again", a re-click.
It keeps the microphone as the person left it, and so does a moderator's move, so neither opens a microphone that "Join muted" or a mute closed.
The preference from before a muted join returns only when the call is left or the person switches channel themselves (`voice_rejoin_keeps_mute_test.dart`).

Deafen is kept by the session whenever a join replaces a call that was never left, and cleared by a leave.
The app tells the server again once the new connection is up, because the deafened mark lives on the participant.

A mute or unmute asked while the session is still connecting cannot publish or silence anything yet.
The session remembers it and the join opens the microphone accordingly, instead of with what it was started with.

A hang-up waits `kLeaveGoodbyeWait` (2 s) for the SFU to acknowledge the leave, then disposes the room whatever it heard.

## Call lifecycle across devices, restarts and stalls

What the 2026-11-19 call audit found by driving two browsers against a real server and SFU, and the rules that came out of it.

A member is on one call.
Within one room the SFU enforces that itself: a second connection with the same identity ends the first.
Across rooms nothing did, so "Join here", which says the call moves to this device, left the first device in its own channel with an open microphone.
The join webhook now ends the member's call in every other room (`http/voice/voice_one_call.rs`), but only a connection the SFU lists as older than the join, so a join reported late cannot end the call the member has since gone back to.
Bots are exempt, because a program may serve several calls at once.

Which call wins is decided by what the member asked for, not by which connection is newest.
A device that lost its network comes back on its own, and its join is then the newest one: left alone it would end the call its person has since picked up on another device, while the first device sits in a pocket.
It comes back two ways, and each has its own guard.
The SDK reconnects by itself on a token the SFU renewed, without asking this server, so the server remembers the room each member last asked a token for (`voice/asked_calls.rs`) and only a join into that room ends other calls; a join into any other room is itself removed.
After the SDK gives up, `VoiceAutoRejoin` asks for a new token, so that request carries `automatic=true` and the server refuses it with `code: on_call_elsewhere` when the account is on a call in another channel, or in this one on another device.
The client then stops trying and says so; "Try again" is a person's own join, which is never refused this way and moves the call back.
The record of who asked for what is in memory, so after a restart a join with no token on record ends nothing and the member can be on two calls until either hangs up, which is what every join did before this rule.
An older server ignores `automatic`, and an older client never sends it; the webhook rule covers the SDK's reconnect either way.
The device that loses its call is told why: after the SFU accepts the removal the server sends that account a `voice.removed` frame with `reason: other_device`, and the client says "Your call moved to another device." instead of "You're no longer in this call."
The frame and the SFU's drop race, so the client takes either order: a frame first marks the call, and the drop that follows reads as moved; a drop first is shown as a removal until the frame replaces its text and cancels any comeback queued for it.
Within one room the SFU's own duplicate-identity drop already names the other device once the roster confirms it.
After the other device hangs up, the first can still be offered "Join here" for a call nobody is in, until its next roster read of that channel drops the sighting (`voiceSelfSeenTtl` bounds it at 90 s).

The SFU's "duplicate identity" does not mean another device.
A client whose signalling stalls reconnects with the same identity while the SFU still holds the old connection, and the SFU ends one of the two as a duplicate.
When it ends the one the client is listening on, the client is told it joined from another device, which used to end the call for good.
Freezing the SFU for 25 s (`docker pause`) did this to both people of a two-person call, and the room kept a silent connection for each of them for another 37 s.
Only the room can tell the two cases apart, so that drop is queued for a rejoin like a lost connection and the attempt first reads the roster: `this_device` false for this account means another device holds the call, and it stays there (`voice_rejoin.dart`).
A roster that cannot be read (an SFU the server cannot reach, a rate limit, a network that is still coming back) says neither, so the blame stays and the next attempt asks again instead of joining.
Reading a failed request as "not listed" was the larger way a blamed drop took a call back from the device its person had just moved to, larger than the stale listing below, because a failing network is exactly when a drop is blamed.
When the attempts run out with the room never read, the call stays ended with "Try again".
The roster is cached for 2 s and the first attempt waits 2 s, so a listing from before the other device's join is unlikely but not impossible.
The rejoin that follows is marked `automatic`, and the server checks the room again, uncached, before it hands out the token, so a stale listing no longer costs the other device its call on a server that knows the parameter.

A heartbeat is keyed by member and channel, not by device.
A device that lost its call to another device must therefore not send the forget when its person dismisses the ended call, or it ends the other device's place on record until that device's next beat.
That holds from the moment the SFU blames another device, before the roster has answered, and after a refused automatic rejoin: until something says the call is this device's again, its place on record is not this device's to end.
The heartbeat lets go of the call at that same moment, because a hang-up is not the only thing that forgets: a switch to another call, failed or not, forgets the call it last proved.
When the drop was this device's own reconnect after all, the cost is a record that goes stale and is swept 40 s later.
A switch never passes through a leave, so the heartbeat itself forgets the call it last proved when it starts proving another.
A switch that fails ends the call switched from and tells the server so, whether the server refused it (a full room, no permission, the server unreachable) with the session still in the old room, or the SFU connect failed after the session had already left it.
A hang-up in the middle of a switch forgets both the call being joined and the one switched from.

A join waits its turn behind the join before it, and a hang-up asked in between is the newer ask: the queued join opens nothing.
Before that guard, a tap, a second tap and a hang-up in quick succession left a live call with an open microphone that the app showed as left and sent no heartbeat for.

The server restarting mid-call loses heartbeats, live state, rings and notice windows, and keeps the calls: media never touches the server.
Measured against a real restart, both clients kept their connections, their next heartbeat (15 s at most) put them back on record, and mute, leave and rejoin all worked afterwards.
Voice sessions are the exception that needed code: they open on a join webhook that never repeats for someone already in the room, so startup now asks the SFU who is on each call that had a session open and opens one for everyone it lists, under the connection they have now.
That includes a member who reconnected or joined while the server was down, whose webhook nobody received.
A call that began entirely during the downtime is not found, because only channels with a session left open are asked about; its members get sessions at their next join.
If the SFU stops answering part way, the calls not yet asked about keep their sessions closed, and the log says how many.

The SFU restarting is a full reconnect for everyone.
A quick restart had both clients back in about 2 s with mute state intact.
Down for 70 s, longer than the SDK's own 44 s of retries, both clients came back through the automatic rejoin about 27 s after the SFU did, which is the 30 s tail of `VoiceAutoRejoin.defaultDelays`.

An SFU token outlives its 120 s: the SFU renews the token of everyone it accepts.
A client holding a renewed token can rejoin after losing Connect without asking the server, so the join webhook checks View and Connect for every join it reports.

On Android the call foreground service must stay up from a drop until the rejoin settles.
Android refuses to start it from the background, so a call that dropped and came back off screen had no microphone.

Not verified here, and needing a real phone: a rejoin racing the previous leave on iOS (the #2427 fix), Wi-Fi to cellular handover, a VPN coming up mid-call, CallKit and the audio session across an interruption (a phone call, Siri), Android audio focus loss, and the Android foreground service rule above.
`docs/PHONE-TESTER-CHECKLIST.md` lists the steps.

## Sync generations

`SyncController` bumps a generation on every stop, fresh start and dispose.
A run superseded mid-flight, such as a sign-out landing during catch-up or a second start racing the first, notices at its next checkpoint rather than finishing and writing stale data into a store a newer run already cleared.
Every await that is followed by a write has to re-check it, including the ones inside the channel refresher, which is why that takes a predicate rather than being trusted to finish quickly.

The ticket mint and the socket connect are network round trips too.
A stop landing inside either used to return from start having already assigned a socket the superseding teardown had run too early to see, leaving it live and applying frames with nothing left holding a handle to close it.
The catch-up, event applier, reconnector and session-end cleanup are separate classes in `sync/providers` that are told whether a given generation is still current.

## The private surface sweep

`crates/slimm-server/tests/it_infra/private_surface/`

One deployment holds a private category with a synced channel, a private voice channel, a thread, a webhook, a file, a direct message and a group, and everything private in it carries a canary word.
A module is installed, approved to schedule and to hear calls, and armed for the private voice channel.
Two sweeps walk `schema/openapi.yaml`, so a route is asked from the day it is documented, with no list to keep up.
Being asked is not the same as being covered: "What the sweep cannot see" below says where the difference is.

- The read sweep sends every GET with every private id in its path, and the search routes with every canary as the query.
  An answer may contain neither a canary nor a private id the request did not name.
- The ask-twice sweep sends every route twice: once naming private ids in its path, query and body, and once naming ids that name nothing.
  The two answers must match, status and error text alike, with a success compared only as a success.
  A difference means the route acted on, or admitted to, something its caller cannot see.

They run for a plain member, for a bot with no permissions, and for a manager holding every permission but ADMINISTRATOR; the read sweep also runs for a member who was in the channel and lost it.
A control run as the admin must meet every canary, so a sweep that stops finding things because the world broke fails too.

What the sweep found on 2026-11-19, each now with its own test beside the route:

- Naming a hidden channel on an upload answered differently from naming none, and a hidden channel's ATTACH_FILES overwrite lent an upload to someone who could not see it.
- MANAGE_ROLES read and wrote the overwrites of a channel, and of a category, its holder could not see.
  A deny is not a grant, so the grant ceiling never stopped a manager shutting a private channel's own members out, and on a category the ceiling was the deployment-wide set, so they could let themselves in.
- MANAGE_CHANNELS renamed and deleted a channel its holder could not see, and the rename answered with its name and topic.
- MANAGE_SERVER read, counted and pruned a hidden channel's retention, and listed, renamed, rotated and revoked the webhooks of one.
- MANAGE_CHANNELS was listed every category, private ones included, and renamed, deleted, reordered and filed channels under ones its holder could not see (decision 0011's third pass).
  A category such a holder is listed only as a heading answers rename, move, delete and filing under it as a missing one too, and one holding a hidden sub-category is not theirs to move or delete; both have their own tests beside the sweep (`it_spaces/category_heading_only.rs`, `it_spaces/category_manage_hidden.rs`), since the sweep's world has neither.
  The one existence leak accepted on purpose: a category over a hidden sub-category is listed `manageable: false, fileable: true` and renames where a move answers 404, which says a hidden sub-category is there without naming it (decision 0011's third pass).

The rule they all broke is decision 0011's: a channel's permissions stop at the channel, whatever the caller holds deployment-wide, and only ADMINISTRATOR sees everything.
A route that takes a channel, category or message id therefore answers a hidden one exactly as it answers one that does not exist, before any other validation of the request.

One thing a manager is told by design is skipped by name in `mod.rs`: the audit log names what was changed.
The sweep does not reach the websocket, push, voice with a live SFU, or call transcripts, which keep their own tests.
The routes in `NEVER` (`probe.rs`) are not asked, because they end the session the sweep runs with or keep a limit of their own on disk.

### What the sweep cannot see

A review of the first version found five routes it walked past, all settings routes that take a channel id in their body and checked only its kind: a module's schedule channel and call-audio list, the welcome channel, the rules channel, and the storage report's ranked channels.
Each was a MANAGE_SERVER holder reaching a channel they cannot see; each now needs the caller's own VIEW_CHANNEL there (and SEND_MESSAGES where the setting makes something post), and has a test beside the route.
The sweep missed them for three reasons, and only the first two are closed.

- A body that does not parse is refused the same way for both asks, so nothing in it is compared.
  About fifty routes were blind this way, for want of one required field each.
  `loaded_body` now carries every required field, `its_own_fields` holds the shapes two routes disagree on, and the ask-twice sweep fails on any refusal that reads like a parse error (`never_read`) unless the route is in `UNREAD_BODIES` with its reason.
  A new route with a new required field therefore fails the sweep until the field is added.
- A path parameter the sweep had no id for got a channel id and answered 404 before the body was read.
  `candidates` now gives `{moduleId}` the installed module and `{webhookId}` the private webhook.
  Role, emoji, clip, theme, report, export, upload, favourite, source and transcript ids still get a channel id, so the body of a route under one of those is not reached.
- The read sweep finds only what the world holds.
  The world has no report, no export, no call transcript, no schedule channel and no welcome or rules channel set to a private channel, so a GET that would name one of those is not tested here.

Three more limits are worth knowing before trusting a green run.

- A refusal the handler writes itself, before it looks at the ids, is as blind as a parse error and is not detected: a kind that must be one of two words, a list that needs one to five entries.
  Listing every 400 the manager's sweep meets (print `named` in `ask_twice`) shows them; on 2026-11-19 they were favourites, a canvas batch, an interaction form, a module hook, a media slot and the push and schedule settings.
- The sweep changes the deployment as it goes, so a route asked late may meet a public channel or message an earlier route deleted.
  The module is put back before every ask (`keep_the_module`); nothing else is.
- A success is compared only as a success, so a route that succeeds for both asks but acts on the private id for one of them passes.

Known and left: an installed module's `schedule_channel_id` is shown to every MANAGE_SERVER holder in the Dock's module list, and moving a schedule takes the module's overwrite off the previous channel without asking whether the caller can see it.
An administrator who sets the rules channel to a private channel publishes its id to every member through `GET /space/rules`; that is the administrator's choice, not a leak.

## Sync convergence

The local store has two cursors per channel, and each one is a claim.
The message cursor says every message seq through it is either held or gone.
The op cursor says every edit and delete through it has been applied.
A cursor that moves without its claim being true is never corrected, because catch-up only asks for what comes after it.
The rules below are what keep the claims true; each was a bug found by `sync_convergence_property_test.dart` or by reading, and each is pinned in `sync_convergence_findings_test.dart`.

- A live op is written first and its cursor moves second.
  A write that fails then leaves the op ahead of the cursor, and the next catch-up delivers it.
- A channel with no op cursor adopts the server's head only while it holds no messages.
  One that already holds some (a channel that appeared this session and took its first messages live, or one opened before its first catch-up landed) refetches its newest page instead, since ops before that head may name rows it holds.
  That refetch rereads every page from the newest down to the oldest row held, not only the newest one, so history the user paged in stays and an op on it from before the head is still caught.
  It swaps the rows in one write (`MessageStore.replaceHeld`) and moves the op cursor only once the pages are stored, so an open channel is never shown empty.
  The swap only drops rows inside the span the pages cover, or below it once a short page proved the channel's start.
  The pages are written without the covered-row rule below: they are the server's own answer for their span, and where a first write started the cursor is known only to the store that made it.
  A server `reset` still clears first, because its cursor has to rewind.
  It also restarts the channel's paging state (`channelHistoryProvider` and the extras' hydrated ranges), which would otherwise page on from below rows that are no longer held and leave a hole.
- A live op starts a missing op cursor only when it is op 1.
  Any other would start it past ops nobody applied.
- An edit op in a catch-up page at or below the op cursor is skipped.
  Its content is the text as the page was read, and live frames applied since may be newer.
  That check and the write are separate awaits, so `MessageStore.applyEdit` also refuses an edit whose stamp is older than the row's.
- A delete is final, so it is applied whatever the op cursor says: a live frame the cursor covers and a catch-up op at or below it both still drop the row and are remembered.
  Only the cursor move is skipped.
  The op cursor is shared by every tab on the database and the record of recent deletes is not, so a tab that skipped a delete because another tab had applied it would store the message again from a history page read before it.
- A created frame at or below the message cursor is dropped unless the row is held.
  The cursor only passes a message that catch-up delivered, so a missing row was deleted since.
  This is also what stops a second browser tab, which shares the database but not the in-memory record of recent deletes, from storing a message again after the first tab deleted it.
- A row in a catch-up page at or below the message cursor is written only when it is already held, for the same reason.
  The cursor can pass a page still in flight: live frames land first, or the other tab applied its own page.
- Neither of those two rules reaches below where a first write started the cursor.
  A channel with no cursor takes it from the first rows written, whatever brought them: the newest page when the channel is opened, or the answer to a send.
  Nothing older than those rows was delivered, so an older row arriving afterwards (the first catch-up page, a frame held during the connect) is stored, not read as deleted.
  The store remembers that starting point in memory (`cursorStartedAbove`); the property test's model does not exercise it, `channel_screen_day_divider_sync_race_test.dart` and the two tests named for it do.
- A server delete is remembered whatever the row's state, including a send still waiting for its answer.
  A catch-up can deliver the delete of a message whose send request has not answered yet, and the answer would otherwise store it again.
  Only the user dropping an unsent message (`discardUnsent`) is not remembered, because that send may have landed and then belongs in the channel.
- Catch-up moves the message cursor to `latest_seq`, the server's head, once a scope's page is complete.
  A deleted message keeps its seq, so the page alone can end short of the head, and a late frame for one of those deleted messages would otherwise look like the next message.
  The standing seq (what the unread dot reads) does not move with it.

The property test drives a real `SyncController` and store against `test/support/sync_model_server.dart`, a small model of `http/sync.rs` and `http/sync_ops.rs`.
It loses, repeats and reorders live frames, and holds catch-up answers so they land after frames that are newer than they are.
After one quiet catch-up the store must agree with the model: nothing missing above the oldest held row, nothing stale, nothing the server deleted.
A second test runs two controllers over one database, as two browser tabs do, each with its own wire.
That one is held to what a single socket can do (frames in order, a loss drops everything in flight and is followed by a catch-up), because a tab that applies a delete it never saw created is not something a socket produces.
`SLIMM_FULL_FUZZ=1` runs the full seed range.
The two-tab case also runs in a real browser: the e2e scenario in `scripts/lib/e2e_tabs_delete.py` holds one tab's script with the debugger while the other sees a message arrive and go, then lets it replay both frames.
The lifecycle freeze (`Page.setWebLifecycleState`) looks like the natural tool and is not: a headless tab ignores it, and the scenario passed with the rule switched off.
When `sync.rs` changes what a scope answers, change the model with it.

Known gaps, none of them fixed here:

- Where a first write started a cursor (`cursorStartedAbove`) is kept per store, so it is lost on a restart and unknown to a second tab.
  There, a created frame or a row of a `/sync` page still in flight that sits below that start is read as deleted and dropped until the channel is opened, when its newest page fills it.
- Pages written with `CursorAdvance.whenContiguous` (the page on opening a channel or a thread, scroll-back) are outside the covered-row rule and rely on the record of recent deletes alone.
  A tab that never sees a delete, because its frame was lost and the other tab moved the shared op cursor past it before this tab's catch-up asked, still stores the message from a page read before the delete.
- The first-catch-up refetch stops after `channelWindowCeiling` rows.
  Rows held below that are left as they are, unchecked against ops from before the head; no window shows them and the retention sweep drops them.
- Two edits with the same `edited_at` stamp are not ordered; the one written last stands.
- Against a server that predates `latest_seq`, a created frame for a message deleted before a reset read its page is still stored.
- Reactions, poll tallies and thread counts are not sequenced; a reconnect refetches the open channels' pages for them (see `open_channel_rehydrate.dart`).
  Pins are not sequenced either and are not on a message page, so the same reconnect rereads each open channel's pin list (`sync_live_refresh.dart`).
- A send that reached the server, whose answer was lost, and which was then deleted elsewhere is answered as sent when it is retried, because the id still matches the deleted row.

## Account scopes

`AccountRoot` keeps an `UncontrolledProviderScope` mounted for every container the `AccountHost` tracks, and only the active one has the app under it.
Never mount a container under a scope that can unmount while the container lives on, unless another scope for it stays mounted.

Riverpod 2.6 queues provider refreshes and `autoDispose` disposals in the container's scheduler.
With a scope mounted, the scheduler hands the queue to the scope's element, which runs it on its next build.
If that element unmounts first the queue is dropped, and the scheduler still believes a run is pending, so it never asks for another.
The container then keeps every `autoDispose` provider it ever built and stops telling listeners about a derived provider that changed.

The root's scope is the only scope a container has.
A row that names another account, in the switcher, the call pill or the share step, is a `ServerIdentity`: it listens to that account's container with `container.listen` and mounts nothing.
It used to mount a second scope, and that is not safe.
Riverpod hands a queued run to every scope of a container and the first one to build runs it.
A switch unmounts the app tree in the frame it happens, so the second scope never built and kept the run; the next thing the container queued, which the unmount itself causes, found it still held and a debug build stopped with "Only one task can be scheduled at a time".
Re-pointing a scope at another container fails the same way, since Riverpod registers a scope on mount and unregisters it on unmount only.

A widget that listens to a container it is not under has two things to mind, both in `account_server_label.dart`.
That container's scope refreshes it while building, and nothing outside the scope may be marked then, so a change heard during a build is taken after the frame.
And the root lists the active scope first, so a tree torn down in order lets go of the other containers while their scopes still stand; a container with no scope falls back to a timer, which a widget test reports as pending.

A container's queue runs on a frame, and a window hidden to the tray draws none.
A listener that must act then listens to a select off the notifier (`voiceFlagsAtOnce`, `appFocusedAtOnce`), never to a provider derived from it.
Inside such a listener the derived provider has not caught up yet, so read the select there too.

`test/features/accounts/account_root_scope_test.dart` holds the cases for the queue: disposal after leaving, disposal and refresh after coming back, refresh while out of view, an account out of view whose name was shown and hidden again, and leaving an account whose own name is on screen.
`account_root_call_test.dart` holds the call state reaching the host with no frame drawn, and `server_identity_test.dart` the row.
The multi-account widget tests mount the real root through `HostRoot`.
The soak harness's smoke run (`docs/soak-harness.md`) fails on the same fault, as live-event listeners that keep climbing.

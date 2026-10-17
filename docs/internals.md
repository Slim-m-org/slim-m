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
`authorize` no longer asks one question: a canvas frame is gated on `VIEW_CHANNEL` *and* `USE_CANVAS`, since the read route requires both and a member denied the second by an overwrite must not be handed over the socket what `GET /canvas/objects` refuses them.
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

`q` reaches FTS5 close to as-is, so a caller may use its mini query language (`AND`/`OR`/`NOT`, `"phrase"`, a trailing `*` prefix).
That is safe against leaking another channel: the index has exactly one column (`content`), so a query string has no other column to pivot to, and the channel restriction is an ordinary SQL predicate the query text can never reach, never part of the `MATCH` expression itself.
See [`crate::store::Store::search_messages`] for the rest of that reasoning and for how a malformed query surfaces as [`SearchError::InvalidQuery`] rather than a 500: SQLite only validates FTS5 syntax once the statement runs.

The operators are parsed client-side (`message_search_query.dart`), which is why this file only ever sees them as already-split query parameters - `q` never carries `from:nick` as literal text a caller could exploit to widen a channel restriction the way `q` itself cannot.

Channel and member search need no route here at all: both are already answered from data the client already holds permission-correctly.
`GET /channels` only ever lists what [`crate::store::Store::visible_channels`] grants, so the client's local channel list is never wider than that; the member list (`GET /members`) is deployment-wide by design (see `http::users`'s own doc comment), not scoped to a channel, so there is no per-channel visibility question to get wrong there.
The command palette (`command_palette_items.dart`) filters both lists by name locally.

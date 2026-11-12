<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Server code

Seven specialists went over `crates/slimm-server` - HTTP core, HTTP routes, store core, store rest, the standalone modules, a duplication pass, and two performance passes (server and database) - and every finding was then put through an adversarial refutation round.
Twelve findings were rejected outright, several for the right reason: the thing was already a written decision (the DM exclusion in `list_channels`, the refusal to rely on `ANALYZE`), already pinned by a test the reviewer had not opened (`tests/it_spaces/member_timeout.rs` covers the batched-timeout equivalence a reviewer called structurally invisible), or already registered as debt in `scripts/file-budget-allow.txt`.
That is the healthy half: the load-bearing parts of this crate - the permission evaluator, the batched permission paths and their equivalence tests, the invite gate's byte-identical refusals, the router-derived capability probe, `begin_write`'s `BEGIN IMMEDIATE` discipline - hold up when pushed on.

Two findings are serious and both are structural rather than typo-shaped.
Role *removal* has no containment guard, which makes the anti-escalation rule the project uses in place of a role hierarchy walkable in one request.
And WebSocket fan-out re-evaluates permissions from scratch per event per connection while three modules publish no events at all, so the same code path is both the crate's largest recurring cost and the reason a revoked channel view never reaches a live client.

Below that, two patterns dominate and they are the same pattern seen twice.
A rule that must hold everywhere is spelled out by hand at every call site - the rate-limit charge (47 hand-pasted lines, six routes missing it), the authorization gate (roughly two dozen inlined copies behind six differently-named helpers), the overwrite precedence bucketing (three copies), the id-list parser (two byte-identical copies).
And close to twenty doc comments describe behaviour the code does not have, several of which are precisely what let the defect underneath them survive review.

## Correctness and security

### High: revoking, deleting or rewriting a role has no containment check, and shedding a role is a channel-level escalation

`crates/slimm-server/src/http/roles.rs:192` (`unassign`), `:144` (`delete`), `:125` (`update`).

`assign` correctly refuses to grant a permission the caller does not hold (`roles.rs:182`).
The three routes that take permissions away check only `MANAGE_ROLES` and then act.
Store-side, `unassign_role` and `delete_role` guard only the transition to zero administrators, not who is being demoted.

Two consequences.
With two administrators, one can strip the other's role; any `MANAGE_ROLES` holder can delete or neuter a role carrying `MANAGE_SERVER` or `BAN_MEMBERS` they do not hold, removing it from every holder at once.
The second is sharper and was missed by the first pass: a role-tier deny only applies to roles the user actually holds (`store/permissions.rs:281`), and `evaluate` makes the role tier deny-wins, so a `MANAGE_ROLES` holder can unassign a deny-bearing role *from themselves* and get the `@everyone` bit back - entering a channel the overwrite model denied them.

That is exactly the walk-around `http/overwrites.rs:157` already refuses on the only other route that can hand a bit back, and `http/members.rs:283` already implements the containment check for moderation.
`tests/it_spaces/member_moderation_routes.rs:6` states the principle: "slim-m has no role hierarchy, so the rule doing that job is permission containment."
The grant direction enforces it and the removal direction does not.

Shape of a fix: apply the same containment predicate in the removal direction on all three routes, including when caller equals target (unlike `members.rs`, which refuses self-moderation outright).
If any of the three is meant to stay open, that belongs in `store/roles.rs`'s module doc as a decision, not as silence.

### High: fan-out costs five queries per event per connection, and no role, overwrite or channel change is published at all

`crates/slimm-server/src/http/ws.rs:337`.

Confirmed independently by the perf pass and the duplication pass.
`authorize` calls `has_permission` once per delivered event in every connection task, and that resolves to five queries (channel, two role queries, overwrites, timeout deny), six on a typing frame.
`MAX_CONNECTIONS` is 1024 against a pool of 8 shared with the write path.
CLAUDE.md records this as open at "four queries"; it is five.

The half that is not merely performance: `hub.publish` appears in nine modules and in none of `http/roles.rs`, `http/overwrites.rs` or `http/channels.rs`.
A role edit, a role assign or unassign, an overwrite set or clear, and channel create or delete reach no live client, so the rail keeps showing a channel whose view was just revoked until the client reconnects.
That is a live staleness bug independent of any cache, and it is also the prerequisite for ever invalidating one.

Shape of a fix: add the missing events first and separately, since they fix the staleness on their own; then a per-connection permission cache invalidated by them, with `MemberTimeoutChanged` and `MemberRemoved` already covering the other two edges.
Downgraded from critical only because the stated target is small friend groups, where 10 to 50 sockets is single-digit milliseconds per message rather than the 1024-socket figure.

### Medium: six mutating routes charge no rate limit, and the limiter's own class doc names one of them

Seen from four directions (HTTP core, HTTP routes, duplication, performance), which is why this is the highest-confidence item in the set.

| Route | Handler |
| --- | --- |
| `PUT /channels/{id}/read` | `http/sync.rs:110` |
| `POST /sync` | `http/sync.rs:147` |
| `POST /invites` | `http/invites.rs:146` |
| `DELETE /invites/{code}` | `http/invites.rs:193` |
| `DELETE /devices/{id}` | `http/safety.rs:84` |
| `POST /auth/logout`, account deletion | `http/auth.rs:222`, `:235` |

`ratelimit.rs:33` documents `Class::Write` as "Ordinary authenticated writes (send, edit, mark read)", and mark-read is the one that does not charge it.
`PUT .../read` is the exposed one: it needs only `VIEW_CHANNEL`, so any member can loop unbounded writes at SQLite's single writer, which is the failure `invites::redeem`'s own comment describes paying for.
`POST /sync` is worse in cost terms - up to 200 scopes, five queries each, unthrottled.
`tests/it_chat/pins.rs:391` and `tests/it_chat/polls.rs:388` both open with "Every other mutating route in this codebase charges a rate limit", so the project asserts this route by route, and the phase-3 audit already found the same omission on `PATCH /messages/{id}`.

The root cause is that `enforce(...)` is a hand-pasted first statement in 47 handlers, each of which also threads a `parts: Parts` clone it uses for nothing else (the authenticated branch of `limit_key` returns before touching it).
Shape of a fix: fold auth and the limit into one extractor, following the `RateLimited<C>` precedent already in `extract.rs:86`, so the class is declared in the signature and a route with no limit says so visibly.
Decide the three session routes deliberately while doing it, and add the 429 to the affected operations in `schema/openapi.yaml`.

### Medium: `messages_fts` is keyed on `messages.rowid`, the exact licence migration 0015 refused for the R-Tree

`crates/slimm-server/migrations/0002_core_schema.sql:230`.

`messages` has `PRIMARY KEY (channel_id, seq)` and no `INTEGER PRIMARY KEY` alias, and the FTS index uses `content_rowid='rowid'`.
`0015_canvas_rtree.sql:17` spells out the consequence for the identical situation - VACUUM may renumber rowids, and "the first place it lands is the `VACUUM INTO` hot copy the backup story is built on" - fixed it for `canvas_objects`, and did not touch FTS.
`docs/ROADMAP.md:318` names `VACUUM INTO` as the Phase 9 backup mechanism.

After a VACUUM, or inside a restored copy, a search can return messages that do not contain the query and miss the ones that do, silently.
It is latent rather than live: nothing runs VACUUM today, and because messages are only ever soft-deleted the rowid sequence is gapless, so a VACUUM would in practice reassign the same numbers.
That is a licence rather than a guarantee, which is the standard 0015 itself applied.

Shape of a fix: give `messages` an explicit rowid alias and rebuild the FTS table against it, and pin the property with a test the way `tests/it_canvas/canvas_index.rs` pins the plan.
The rebuild is the real cost and it is far cheaper before the Phase 9 backup work than after.

### Medium: a retried poll send whose message was deleted returns 500

`crates/slimm-server/src/store/polls.rs:142`.

The idempotency probe uses `fetch_live_message`, whose SQL ends `AND m.deleted_at IS NULL`.
`messages.rs:145` does the opposite for the same probe and explains why in as many words: filtering deleted rows out let it fall through to an INSERT that hit the unique id and mapped to a 500.
`client/packages/api/lib/src/client_messages.dart:176` tells callers `sendPollMessage` is "Idempotent by [id] exactly like `SlimmApi.sendMessage`".
Nothing in `tests/it_chat/polls.rs` exercises a repeated id.

The probe's doc comment states the opposite of what the function does, claiming it mirrors the ordinary send path - which is what would let this pass review.

Shape of a fix: point the probe at the projection with no `deleted_at` predicate (the free helper already exists), keep the channel and author scoping so a reused foreign id still yields 409, and add the retry-after-delete test.

### Medium: password recovery commits the new password before revoking any session

`crates/slimm-server/src/store/recovery.rs:134`.

The transaction claiming the one-time code and writing the password commits at line 134.
The live-session lookup and the per-session revocations then run afterwards, each `revoke_session` opening its own transaction.
The doc claims parity with `delete_account`, which does the equivalent work inside a single transaction.
`recovery.rs:11` states the purpose: "recovering an account that may be compromised, not just changing its password out from under a session an attacker still holds".

A pool error, a `?` on any iteration, or a process death after the commit leaves the password changed, the code spent and unusable, and the attacker's sessions live.
`http/recovery.rs:92` publishes `SessionRevoked` only on whole-call success, so a mid-loop failure also leaves already-revoked sockets open.

Shape of a fix: move the session lookup and revocations into the same transaction as the claim and password write, using the row-level helper `revoke_session` already delegates to, and return the ids for socket closure.
`remove_device` (`store/safety.rs:116`) has the same read-then-write-across-four-statements shape and wants the same treatment.

### Medium: the presence idle clock is only ever reset by a typing frame

`crates/slimm-server/src/presence.rs:33`.

`IDLE_TIMEOUT`'s doc says the clock is reset by "a ping, a typing refresh, anything inbound".
The only caller of `touch` in the crate is `http/ws/signals.rs:95`, inside `handle_typing`, and it sits *after* that frame's rate-limit and channel-permission checks.
The ping branch does not touch.
The client never sends a ping either: `WsChannel.ping()` exists at `client/packages/api/lib/src/events.dart:244` and nothing in `packages/app` calls it.

So a user reading, sending over REST, reacting, or sitting in a voice call is reported Away after ten minutes.
Related and separate: nothing publishes `PresenceChanged` when the idle deadline lapses, so a client that connected before its peer went idle keeps rendering them Online for the life of the socket.
Away is effectively fetch-only while every other presence state is live.

Shape of a fix: touch where a frame parses in the read loop rather than inside one handler, and decide explicitly whether the idle transition is announced or is deliberately fetch-only - then write down whichever it is.

### Medium: a pool timeout during fan-out drops a message frame permanently, with no log

`crates/slimm-server/src/http/ws.rs:340`.

`has_permission(...).await.unwrap_or(false)` collapses a store error into a denial, which the doc says is deliberate ("a permission-check error fails closed").
`ws.rs` contains no `tracing::` call at all outside the `Lagged` branch.
The consequence is worse than fail-closed: the client cursor is a monotone high-water mark (`client/packages/data/lib/src/message_store.dart:251`) and `/sync` returns strictly `after_seq`, so if seq N is dropped and N+1 delivered, no future `/sync` will ever ask for N again.

Silent permanent loss from one client's view, likeliest exactly when the server is busiest.
Shape of a fix: match the `Result` rather than collapsing it - keep the drop for a genuine denial, log the error case with channel and user, and decide whether to close the socket so the client resyncs, which is what the `Lagged` branch already does for the analogous case.

### Medium: every sign-in mints a device row that nothing removes, and `list_devices` filters nothing

`crates/slimm-server/src/store/sessions.rs:384`, read by `store/safety.rs:88`.

Logout clears the device's push columns and stamps `sessions.revoked_at`; it never touches the device row, and `DELETE FROM devices` exists only in account deletion and explicit device removal.
`list_devices` has no liveness predicate at all.

The one place a user checks what has access to their account lists every device row the account ever created, all identically named from `device_name`, distinguishable only by `created_at`.
Nine dead entries beside one live one makes the control useless for its purpose.
`0020_member_timeouts.sql:10` wrote down its decision to keep an elapsed row; nothing decides this one.

Shape of a fix: two separable pieces - filter the list to devices with an unrevoked session (or delete the row at logout), and extend the existing bounded token sweep to drop long-revoked sessions and the devices left with none, recording the retention decision in the migration.

### Low: the WebSocket typing gate fails open on a store error

`crates/slimm-server/src/http/ws/signals.rs:42`.

`presence_status` returns `None` both when the account is gone and when the store read fails, because of `.ok().flatten()`.
`ws.rs:350` gates a typing frame on `== Some(Status::Offline)`, so `None` bypasses the gate and one typing frame for an appear-offline user reaches every viewer in the channel.
The sibling gate 60 lines up gets it right and says so: "A permission-check error fails closed (no delivery)".
The doc comment on `presence_status` claims `None` happens only if the account is gone, which is what stops a reader checking.

Narrow trigger (one indexed read on the read pool under WAL), so low - but the doc contradiction is the durable half.

### Low: the invite gate reads a claim marker a later transaction writes

`crates/slimm-server/src/http/auth.rs:152`, `store/sessions.rs:272`.

The gate reads `SELECT 1 FROM roles WHERE is_everyone = 1` inside `register_account`'s transaction, under a comment saying the in-transaction read is what stops a concurrent first registration letting this one in ungated.
That row is written by `bootstrap_deployment`, in a separate transaction the handler runs afterwards.

Downgraded to low by both reviewers who looked at it: the window exists only while the deployment is unclaimed, where registration is deliberately open and the racer's better move is simply to register first and become administrator.
What survives is the split failure mode - if `bootstrap_deployment` errors, or the process dies between the two calls, the account has committed into a permanently unclaimed deployment holding no roles, and the next registrant claims it and becomes administrator over that account's data.

Shape of a fix: make the claim decision depend on state the account-inserting transaction can see, which also removes the split failure mode; a concurrent double-registration test would pin it.

### Low: remaining correctness items

| What | Where | Why it matters |
| --- | --- | --- |
| Role names, channel names and channel topics skip the bidi and zero-width predicate display names are held to | `http/roles.rs:248`, `http/channels.rs:260`, `:243` vs `http/auth.rs:307` | A role name renders as a badge beside every member, so it is the closest analogue to a display name of the three, and it gets the weaker check. Both write paths need an elevated bit, hence low. |
| `to_dto` indexes a Vec instead of handling empty | `http/users.rs:107` | `Vec::remove(0)` panics; safe only because of an invariant in a different function. A panic aborts the connection instead of returning the uniform JSON 500. |
| `class_of`'s wildcard silently assigns the loosest budget | `http/extract.rs:93` | A new unauthenticated class code compiles clean and gets Refresh's budget, twenty times looser on refill, with nothing reporting it. The expensive endpoints here are the unauthenticated ones. |
| Capability probe compares `Allow` entries untrimmed | `http/capability.rs:87` | The safety handshake rests on axum's private comma formatting. RFC 9110 permits `POST, DELETE`; that would make the server advertise that it cannot accept reports when it can, and the client tell a user they have no way to report anyone. |
| A partial push-relay or SFU config logs "not set" for variables that were set, and disables the feature for the process's life | `push.rs:95`, `voice/mod.rs:121` | An operator greps their own variable name, finds it in the config, and sees the log deny it. Diagnosability, not a leak. |
| Attachment fetch validates any-case hex but reads the raw path segment | `http/attachments.rs:156` vs `:194` | An uppercase id passes validation, finds the row, passes the permission check, then 500s on the file read. No shipped client hits it; the defect is that a validator and its consumer disagree on the canonical form. `http/emoji.rs:168` does it correctly. |
| `report_visible_in` collapses store errors into a silent 404 | `http/reports.rs:173` | A transient error is indistinguishable from a deliberate per-channel exclusion in both directions: a moderator sees a shorter queue silently, and a PATCH that hit a locked writer reports "report not found", which a client reads as another moderator having taken it. |
| A failed atomic write leaves a `.tmp-<uuid>` file nothing can name again | `media.rs:259` | Every write that fails partway leaves a file in the attachments directory with a name no code path derives, on a volume already short of space if ENOSPC caused it. |
| `Permissions::ALL` is a hand-listed union of 16 constants | `permissions.rs:69` | It is the ADMINISTRATOR bypass and the grant validity mask. A forgotten bit fails closed - administrators do not get it and requests naming it 400 - so the symptom is a permission that cannot be used at all, debugged at the wrong layer. Two reviewers flagged it; both note an explicit-array test would be a second list that goes stale in the same edit. |
| `rotate_refresh`'s revoked branch rolls back the token spend where `redeem_ws_ticket` commits it | `store/sessions.rs:531` | Unreachable today, and the code says so, but two adjacent single-use-credential paths resolve the same case oppositely and one leaves the credential replayable. |
| Soft-deleted message content stays in `messages.content` and in the FTS index | `store/messages.rs:252`, `migrations/0007:33` | Deletion removes nothing at rest. Every API read path filters correctly, so nothing leaks over HTTP; the guarantee does not survive the file, the Litestream replica, or a future FTS consumer that forgets the predicate. A retention decision to make, not a bug. |
| `reports.snapshot` is retained forever after resolution and nothing ever reads a resolved report | `migrations/0005_safety.sql:17` | The one table that keeps content on purpose keeps it unboundedly, including content whose author has since deleted it or deleted their account. |
| A poll can be created already closed | `http/polls.rs:144` | Accepts a request that provably cannot do what it asks, and pays a real per-channel `seq`, a transcript row and a fan-out for it. `space.rs:59` and `canvas.rs:174` both refuse rather than coerce, with comments saying why. |

## Duplication

Three of these are correctness risks rather than repetition, and they are marked.

### The authorization gate is written out roughly two dozen times behind six differently-named helpers - correctness risk

`http/emoji.rs:189` and `http/space.rs:72` are byte-identical `require_manage_server` functions in two modules.
`http/members.rs:257` is already the general form (`require(state, caller, needed)`) and nothing outside `members.rs` uses it.
Beyond those, `base_permissions` has 15 to 17 call sites across nine modules and `has_permission` 19, most as a bare inlined `if !... { return Err(Forbidden) }`.
Separately, the channel `VIEW_CHANNEL` gate is copy-pasted across twelve handlers in seven files (`http/messages.rs:256`, `:296`, `:362`; `sync.rs:95`, `:120`, `:166`; `pins.rs:128`, `:162`, `:183`; `search.rs:60`; `attachments.rs:170`; `ws.rs:339`), and the comment explaining that it hides channel existence travelled with the copies.

This is a correctness risk, not tidiness: the phase-1 audit found a report-resolution route checking deployment-wide `MANAGE_MESSAGES` where its sibling checked per-channel, and that is exactly what two dozen independently written copies produce.
Reviewers cannot diff two dozen blocks.
No site in this pass was found holding the wrong bit.

Shape of a fix: two shared guards beside `Authed` and `enforce` - one deployment-wide, one per-channel, the latter carrying the hides-existence reasoning as its doc comment - and delete both `require_manage_server` copies.
Keep the variants that return the caller's mask as a ceiling (`roles.rs:215`, `overwrites.rs`); that is a different job, and threading the returned mask would also remove a redundant second `base_permissions` read on the invite-create path (`http/invites.rs:119` re-reads what `:154` already fetched).

### The overwrite precedence bucketing exists three times and crosses the store boundary as a bare `&str` - correctness risk

`store/permissions.rs:277`, `store/permissions_batch.rs:139`, `:228`.

The same three-arm classification deciding which precedence tier an overwrite row lands in - the input to the whole permission model - is written out three times, each ending in a catch-all `_ => {}`.
The `"role"` / `"member"` discriminant is the URL path's vocabulary and the database's column value at once, agreed by hand across 21 sites, and `http/overwrites.rs:115` and `:173` spell the `Target`-to-columns conversion twice within one file.

A typo in any arm makes an overwrite silently stop applying rather than failing, which is the quietest possible way to lose a permission rule.
The equivalence tests in `tests/it_spaces/permissions.rs` are a real backstop and cover base deny, role grant, role deny, member regrant, ADMINISTRATOR, DMs and a ghost channel - but they cover the cases somebody thought to write, and behaviour is identical today only because all three copies happen to agree.

Shape of a fix: one function producing the precedence triple `evaluate` wants, called from all three sites, and promote the target kind to a typed enum with a single string conversion so a misspelling cannot reach the catch-all.

### `member_count` counts members `list_members` excludes, and its doc claims parity - correctness risk

`store/users.rs:113`.

`list_members` (`users.rs:136`) and `administrator_count` (`roles.rs:299`) both exclude `space_removals`; `member_count` does not, while its doc defines itself by reference to `list_members`.
Its one caller puts the number in invite metadata, so a prospective joiner is shown a size that counts people a moderator removed.
The not-removed predicate is spelled four ways across the crate, which is how the next such gap arrives.

Shape of a fix: decide once whether "member" means "has an account" or "is admitted", write it down, and let one predicate serve all three readers.

### The remaining duplication

| What | Where | Note |
| --- | --- | --- |
| The comma-separated id-list parser and its cap of 100 | `http/presence.rs:66` and `http/users.rs:250` | Eleven byte-identical lines including the error string, under two constant names for one number. `presence.rs:28`'s doc asserts the coupling the code cannot enforce - and the copy is exactly where the two endpoints stopped agreeing, since `users.rs` then batches its id resolution and `presence.rs` loops. Found by three specialists. |
| `require_manage_server`, verbatim in two modules | `http/emoji.rs:189`, `http/space.rs:72` | Folded into the gate item above. |
| The eight-column message projection with its author `LEFT JOIN` | nine sites across `store/messages.rs`, `pins.rs`, `polls.rs`, `read_state.rs` | All nine `deleted_at` predicates currently agree, so this is duplication not a live bug - but the pinned and poll paths have to keep agreeing with the list path about which rows are live and how a deleted author's name is suppressed, and the poll divergence above is what that looks like when it breaks. Three sites hand-map the eight fields because they select extra columns. |
| `Store::message_including_deleted` duplicates the free function verbatim | `store/messages.rs:387` vs `:416` | Sixteen lines, three lines below `Store::message`, which already delegates correctly. Confirmed twice. |
| Four hand-rolled lowercase-hex encoders | `auth.rs:151`, `media.rs:131`, `identity.rs:121`, `store/emoji.rs:183` | `media::to_hex` is already `pub` and its own doc names the situation instead of fixing it. `store/emoji.rs` and `store/attachments.rs` share a table and must agree on this representation; one calls `media::to_hex` and one does not. |
| `now_ms` copy-pasted beside the `pub(crate)` original | `http/invites.rs:138` vs `store.rs:71` | The original's doc says out loud that one shared clock is the point. `members.rs` and `polls.rs` import it correctly. `voice/mod.rs:349` is a seconds-resolution third copy. |
| The poisoned-mutex recovery idiom, five times | `ratelimit.rs:121`, `:167`, `presence.rs:227`, `typing.rs:103`, `push.rs:420` | Two of the five are inline and easiest to miss. The policy is documented three times in three wordings, one of them wrong (below). |
| The two LiveKit twirp calls duplicate the whole request-and-status ceremony, including the path prefix | `voice/mod.rs:245`, `voice/roster.rs:55` | The 404 branch means two different things in the two copies (already gone, versus empty room), which is what a reader has to re-derive per copy. |
| `IMMUTABLE_CACHE` declared twice, and the emoji handler re-inserts the identical value | `attachments.rs:36`, `emoji.rs:40`, `:179` | Six lines that do nothing while reading as though they do. `serve`'s doc names two consumers when there are three. |
| `custom_emoji_refusal` duplicates `create_custom_emoji`'s cap-and-name check statement for statement | `store/emoji.rs:73` vs `:109` | The two can drift so the advisory pre-check accepts what the write refuses, which is the one outcome the pre-check exists to avoid. |
| The invite-usability rule encoded three times | `store/invites.rs:37`, `:203`, `:262` | `spend_invite`'s own doc says it is a free function so the two spend paths "cannot drift into two different notions of what usable means"; the check path is a third notion outside that guarantee. The admin list's answer and redemption's answer come from different implementations. |
| Channel creation plus sequence-counter seeding written twice, and the DM kind as a SQL literal in eight places beside the constant defined for it | `store/channels.rs:33`, `store/dms.rs:142` | A third `channel_seq_counters` stream or a new non-null column means finding both paths with nothing linking them. |
| `validate_channel_name` and `validate_role_name` byte-identical, with the 64-char bound spelled five ways | `channels.rs:260`, `roles.rs:248`, `auth.rs:289` | A limit baked into the message string can change in the check while the error still quotes the old number. |
| The variable-length bind loop hand-written four times, and the group-rows-by-message-id fold twice | `users.rs:57`, `reactions.rs:183`, `attachments.rs:163`, `push.rs:187`; `polls.rs:387` already extracted it | Mechanical, but one of the five copies has already been named and extracted a module away. |
| Two test-only account-insert primitives in the store's public API, one carrying a written security warning | `store/sessions.rs:329`, `store.rs:187` | A prose warning ("a route that calls this reopens the hole where anyone could join a claimed deployment without an invite") is standing in for something the compiler could enforce. Note integration tests are separate crates, so a `cfg` feature gate does not work cleanly here. |

## Performance

Nothing here is a measured stall on a friend-group deployment.
What makes several of these worth doing is that the batched primitive they should use already exists, in the same directory, with a doc comment describing the exact bug being repeated.

| Finding | Where | Cost and why |
| --- | --- | --- |
| `POST /sync` loops `has_permission` per scope, up to `MAX_SCOPES` of 200, at five queries each | `http/sync.rs:166` | `store/permissions_batch.rs:177`'s doc describes this bug in the past tense - "the handler used to ask has_permission per channel... 1 + 4C queries for C channels on a request every client fires at startup". The rail listing was converted and the reconnect path, which asks about more channels and has no rate limit, was not. Found twice. Caveat both reviewers flagged: `visible_channels` is built on `list_channels`, which excludes DMs, so a naive swap silently drops every DM scope from sync. |
| `viewers_among`'s DM branch issues one query per candidate for an answer one row already gave, and two comments claim the opposite | `store/permissions_batch.rs:63`, comments at `:37` and `:65` | Candidates are every push-registered account. This is the same N+1 the function exists to remove, inside the function that removed it, and the false comments are the more valuable half of the finding. Found twice. |
| `GET /presence` issues one query per id, up to 100, and no batched `presence_visibility` exists | `http/presence.rs:82`, repeated in `http/voice.rs:179` | The immediate neighbour resolves the same 100 ids in one call (`http/users.rs:262`), and `roles_for_users` two lines further on is the `IN (...)` shape to copy. Under a millisecond even at the ceiling; filed for the pattern divergence. |
| Presence events re-read one durable preference per connection per event | `http/ws/signals.rs:52` | The value changes only through `PATCH /presence`, which already publishes the invalidation signal. Quadratic in users times sockets, so it needs hundreds of simultaneous users to matter. |
| `pins::authorize_manage` runs two full permission evaluations where a union gives the identical answer in one | `http/pins.rs:176` | Ten queries instead of five per pin, and both arms return a bare `Forbidden` so nothing distinguishes them. `http/messages.rs:199` shows the union idiom, and four siblings evaluate once and check bits. Found twice. |
| The DM rail recomputes `MAX(created_at)` by reading every live message in every DM, then does two more round trips per conversation | `store/dms.rs:190`, `:207` | Cost is the caller's total live DM message count, so it degrades exactly as the feature gets used and nothing in the query shape says so. `ORDER BY seq DESC LIMIT 1` plans as a single seek. |
| `refresh_tokens` has no index on `session_id`, unlike both sibling token tables | `store/sessions.rs:796` | Every logout, device revocation and account deletion scans it, while holding the write lock; account deletion pays it once per historical session. `access_tokens_session` and `ws_tickets_session` were both added in the migration that created those tables. |
| The hourly orphaned-attachment sweep re-scans every permanently-attached row forever, holding the write lock | `store/attachments.rs:216` | Cost grows with total attachments for the life of the deployment and never comes back down, for a query whose usual answer is "nothing to delete". `0019`'s own header identifies this anti-pattern for the token sweeps. |
| Six more FK and filter columns unindexed, each on a write path | `channel_overwrites.target_id`, `invites.created_by`, `password_reset_codes.issued_by`/`.user_id`, `member_roles.role_id`, `access_tokens.device_id`, `ws_tickets.device_id`; plus `devices.push_token_ref` (`store/push.rs:77`) and `pinned_messages.message_id` (`migrations/0009_pins.sql:37`) | Mostly human-scale tables where a scan is a few pages, but all run under the single write lock, and the same class of gap has now been found twice - 0019 indexed the sweep and authorship columns and missed these. The systematic answer (generate the unindexed-FK list as a test) is worth more than the individual indexes. |
| The moderation queue is unbounded and pays six queries per report; password reset and four other sites revoke sessions one transaction at a time | `http/reports.rs:87`, `store/safety.rs:297`; `store/recovery.rs:141` and four callers | Open reports accumulate until somebody triages, so the queue's cost is unbounded in a way nothing else on the moderation surface is. The session loops take and release the write lock once per device. |
| `/version` re-reads the server identity row and recomputes four SHA-256 digests on every unauthenticated call | `http.rs:184` | The identity is immutable after first create, and `CAPABILITIES` in the same handler is already memoised in a `OnceLock` as the precedent. |
| The perf benchmarks measure nothing on any hot path, justified by a doc comment that is false | `benches/hot_paths.rs:4` | The comment says the crate exposes only a binary target and cannot be imported; `src/lib.rs` exists and its own header says the opposite. The two benchmarks are `uuid_now_v7` and `version_json_serialize`. Note `perf.yml` is not a regression gate - on PRs it only compiles - so the harm is that nothing above is tracked, not that a gate is fooled. |

## Componentisation and the file budget

`parse_uuid` lives at the bottom of `http/messages.rs:490` and is imported by 13 to 17 sibling modules, none of which have any other reason to depend on the messages feature module.
That is why two authors did not find it and wrote rivals with different error strings (`http/invites.rs:124`, `http/emoji.rs:200`), so one 400 has three different bodies.
`messages.rs` also holds `MessageDto`, `AttachmentDto` and `with_reactions` for four other modules, which is why it sits at 492 lines against a 500-line hard CI failure - eight lines of room for the next message-handling change.
Found by three specialists.

The file-budget register itself has drifted.
`scripts/file-budget-allow.txt:11` records `store/sessions.rs` at 957 with the comment "account deletion is the obvious first split"; that split happened, the file is 809, and the ceiling was never lowered, so the crate's most security-critical file has 148 lines of free regrowth back through the hard limit.
`push.rs`'s entry names a split made three PRs earlier, so its reason line points at a seam that no longer exists and reads as "already tried, nothing left".
The gate already forces an entry out once a file drops to 500 or below (`check-file-budget.sh:70`); what is missing is any tightening between the recorded ceiling and 500.
`http/ws.rs` at 469 lines has an obvious envelope seam its own section comments mark, and `ws/signals.rs:4` already establishes the `ws/` directory and says why.

Two smaller shape items: `parts: Parts` is threaded through 47 handlers to build a rate-limit key the authenticated path never reads (folded into the rate-limit finding above), and `create_custom_emoji` returns a nested `Result` where all fourteen sibling store operations use one error enum with an `Internal` variant.

## Documentation that contradicts the code

Close to twenty places.
Grouped because this is the pattern, not because each is worth a ticket: in at least five cases the wrong comment is what would let the defect under it pass review, and CLAUDE.md's own rule is that a stale note costs more than a missing one.

| Where | What it claims | What is true |
| --- | --- | --- |
| `presence.rs:33` | A ping or "anything inbound" resets the idle clock | Only a typing frame does, and the client never pings |
| `store/polls.rs:414` | The probe mirrors `messages::fetch_message` for idempotency | It filters deleted rows, which is what breaks idempotency |
| `store/messages.rs:405` | "Fetches one live message" | It has no `deleted_at` predicate, which is its whole purpose |
| `http/ws/signals.rs:42` | `None` only if the account is gone | `.ok()` collapses any store error into the same `None` |
| `permissions_batch.rs:37`, `:65` | The DM pair is fetched once, so candidate count stops mattering | Fetched once per candidate |
| `ratelimit.rs:33` | `Class::Write` covers "send, edit, mark read" | Mark-read charges nothing |
| `ratelimit.rs:123` | A poisoned lock "fails open" | It recovers and enforces the limit normally; the two modules that copied the idiom describe it correctly |
| `attachments.rs:34` | `IMMUTABLE_CACHE` is safe because bytes are content-addressed | Its third consumer, `get_avatar` (`users.rs:392`), serves a mutable URL keyed by user id, safe only by a client-side cache-buster convention documented 300 lines away |
| `http.rs:2` | The HTTP surface is liveness, version, auth and messages, and "the WebSocket routes are added as the protocol is built" | 26 route modules, `ws::routes()` merged at `:96` |
| `channels.rs:6`, `store/pins.rs:174`, `messages.rs:452` | Intra-doc links to `Store::base_permissions` and friends | `Store` is not in scope, so they render as literal text; nothing in CI checks rustdoc links |
| `store/timeouts.rs:53`, `store/removals.rs:29`, `migrations/0020:23`, `0021:31` | `issued_by` / `removed_by` are nulled when the moderator's account is deleted | `delete_account` tombstones and never deletes a users row, so no `ON DELETE SET NULL` can ever fire; `member_timeouts` is not covered by account deletion at all |
| `store/permissions_batch.rs:19`, `store.rs:208`, `store.rs:4` | `channel_viewer_ids` is "the recipient set for push fan-out" | Both it and `live_user_ids` are dead - three grep hits repo-wide, all definitions - and fan-out starts from `users_with_push_devices`. The dead path is also the one entry into `viewers_among` that ignores `space_removals` |
| `store/safety.rs:285` | The moderation queue "lands with the admin console in Phase 7" | `list_open_reports` is fifteen lines below it and the screen shipped |
| `store/safety.rs:152` | Two doc comments merged by accident | Hover on a boolean existence probe says it blocks a user; `block_user` has no doc at all, and the deliberate-silence product decision is filed where nobody looks |
| `http/messages.rs:406` | `with_reactions` attaches reactions and polls | It also attaches attachments, which four callers cannot see from the name or the doc |
| `store/permissions_batch.rs:176` | (omission) `visible_channels`'s doc does not mention that its safety depends on `list_channels` filtering DMs in another module | Two specialists disagreed here: one filed it as a latent hole plus a test-coverage gap in the equivalence test (which uses no DM and no administrator), the other rejected it because `bootstrap.rs:123` documents the exclusion as deliberately central and `tests/it_chat/dms.rs:318` pins it end to end for the administrator case. Both are right about their evidence; the residue worth acting on is widening the equivalence test |
| `CLAUDE.md:617`, `docs/STRATEGY.md:172`, `docs/ROADMAP.md:71` | "A single serialized writer plus a read pool" | `db.rs:35` builds one pool of eight connections, any of which may write. `Store::begin_write:167` states the reality correctly. The entire `BEGIN IMMEDIATE` discipline exists *because* there is no serialized writer, so a reader trusting the summary concludes the discipline is unnecessary - which is the worst available conclusion, and the "database is locked" finding in the phase-3 audit is what it costs |
| `scripts/file-budget-allow.txt:11`, `:12` | Names splits as pending | Both were made |

Also in this bucket: `migrations/0019_hot_path_indexes.sql` is the only migration with no SPDX header, because `hygiene.yml:257` checks Rust sources only, and its comment points at `store/sessions.rs` for three UPDATEs that have since moved to `store/account_deletion.rs`.

## Small cleanups

| What | Where |
| --- | --- |
| `upload_avatar`'s size check cannot fire, so the 400 it names is unreachable behind the layer's 413 | `http/users.rs:317` |
| Two `#[serde(default)]` attributes on a `Serialize`-only struct do nothing, while a reader will read them as what keeps the keys on the wire | `http/messages.rs:68`, `:82` |
| `StatusError` is a second error mechanism, contradicting `error.rs`'s claim that every route is uniform; defensible for a plain-text liveness probe, but nothing says so | `http.rs:203` |
| `validate_label`'s caller-supplied message covers one of its three failure modes, so a bidi character in `device_name` produces an error naming no field | `http/auth.rs:289` |
| `push::validate_token` string-matches the field name it was handed to re-derive a message the caller already knows, with a `_ =>` arm that will mislabel a future third field | `http/push.rs:134` |
| `send_poll_message` carries the repo's only `allow(too_many_arguments)`, at the only site that trips it | `store/polls.rs:115` |
| `healthcheck` reads `SLIMM_PORT` directly and re-hardcodes 8080, bypassing `Config` | `lib.rs:171` |
| `Hub::new` and `Hub::with_typing_ttl` duplicate the constructor body instead of delegating, unlike the tracker they wrap | `hub.rs:150` |
| `revoke_invite` discards `rows_affected` with no doc saying a no-op is expected, so a typo'd code reads as revoked; `resolve_report` answers the same question about the same kind of action and returns a bool | `store/invites.rs:153` |
| `delete_account` re-stamps and returns every historical session where `remove_from_space` filters to live ones, publishing one broadcast event per session the account ever opened | `store/account_deletion.rs:77` |
| `overwrite_for` / `set_overwrite` / `delete_overwrite` take `target_type: &str` while the caller holds a typed `Target` | `store/permissions.rs:124` |

## The three I would do first

**1. Containment on role removal (`http/roles.rs`).**
It is the only high-severity security finding, the escalation is reachable by a single request from a `MANAGE_ROLES` holder, the guard already exists in two other modules to copy from, and the fix is small.
Everything else here is either latent, needs a specific failure to fire, or is a cost rather than a hole.

**2. Publish the missing role, overwrite and channel events, then cache per-connection permissions (`http/ws.rs`, `http/roles.rs`, `http/overwrites.rs`, `http/channels.rs`).**
The first half is a live staleness bug on its own - a revoked channel view never reaches a client - and it is also the only thing that makes the cache invalidatable, so the ordering matters.
This is the recorded item that has been open longest and the crate's largest recurring cost.

**3. Make the rate-limit charge an extractor and close the six uncharged routes (`http/extract.rs`).**
Four specialists found it independently, the phase-3 audit already found the identical omission once, and `ratelimit.rs`'s own class doc names a route it does not cover - so the current mechanism has now demonstrably failed twice in the same way.
Moving the charge into the signature also removes `parts: Parts` and its clone from 47 handlers and turns "no limit" into a visible, reviewable choice.

Worth queueing right behind those: the `messages_fts` rowid licence, because it is far cheaper to fix before the Phase 9 `VACUUM INTO` work is written than after, and its failure mode is silent wrong search results.

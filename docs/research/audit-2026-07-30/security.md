<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Security

Nothing critical.
No authentication bypass, no unauthenticated read of member content, no path to escalate a permission bit upward, and no injection surface (every query is a compile-time-checked `sqlx` macro).
The three highest findings are not breaches of the permission model at all: two are availability, reachable by anyone who can open a TCP connection, and the third is a safety feature that records state and then does not act on it while telling the user it has.
The pattern underneath most of the rest is that a security property in this codebase is opt-in per call site rather than structural: the rate-limit charge is a line in a handler, the target-level check on a moderation verb is a call to a helper one module over, and the https rule lives in one dialog.
Where the property was made structural - appear-offline deriving status per receiving connection, the capability probe reading the real router, `link_attachments` being the *only* thing that could authorize a reference - it holds under adversarial reading.
Where it is a line somebody had to remember, it has drifted, and two specialists arrived at the same drift from different directions.

## Availability, reachable with no account

### 1. Behind the reverse proxy this repo ships, every unauthenticated rate-limit bucket is one bucket - high

`crates/slimm-server/src/http/extract.rs:58`

`limit_key` returns `ip:<peer>` for an unauthenticated caller, and `lib.rs:64` wires `into_make_service_with_connect_info::<SocketAddr>()`, so that address is the TCP peer.
Behind `deploy/Caddyfile` (which is `reverse_proxy server:8080` and nothing else) and behind the Traefik on the live box, the peer is always the proxy.
So `Class::Password` (5 burst, one per six seconds) and `Class::InviteCheck` (10 burst, one per ten seconds) are global for the entire internet.
There is no trusted-proxy setting anywhere in the crate; grepping `forwarded|trust_proxy|real_ip` finds only two comment lines, one of which says the proxy "should apply its own per-IP limit as well" - and the shipped Caddyfile applies none, and `deploy/README.md` never mentions rate limiting.

Who has to be able to do what: one anonymous client, one request per second, no account.
That keeps the password bucket permanently empty and every legitimate login and registration gets a 429.
It also fires by accident when a small group signs in together.
The limiter's own fail-closed `MAX_BUCKETS` path and the Argon2 semaphore both sit behind this key, so nothing downstream mitigates it.

Shape: a real per-IP limit in the shipped proxy config, plus an explicit opt-in trust decision in the shape the relay already uses (`RELAY_TRUST_PROXY`), defaulting off so a directly-exposed server keeps the safe peer-address behaviour.
**Closed 2026-07-30, PR #145**, with one correction to the shape above: Caddy has no built-in `rate_limit` directive, so "a real per-IP limit in the shipped proxy config" is not available without a third-party module and a custom build, and the fix had to be server-side. `SLIMM_TRUST_PROXY_HOPS` defaults to 0, and a non-zero value reads `X-Forwarded-For` from the right, which is what a client-supplied prefix cannot reach.

### 2. The HTTP surface has no request timeout and no connection cap - high

`crates/slimm-server/src/http.rs:96`

`http::router` builds roughly 60 routes across 24 sub-routers and applies exactly one layer, `TraceLayer`.
There is no `TimeoutLayer`, `RequestBodyTimeoutLayer`, `ConcurrencyLimit` or `LoadShed` anywhere in the crate, and `axum::serve` is called with no timeouts.
The socket path has both bounds and comments explaining why: `MAX_CONNECTIONS = 1024` claimed through `Hub::try_connect`, a 10s auth deadline, a 10s write timeout, a 4 KiB frame cap.

Who has to be able to do what: anyone who can reach the port, unauthenticated, on any route including `/healthz`.
A request that declares a body and trickles it holds a task and its partial buffer indefinitely, and nothing bounds how many such tasks exist, against a process whose measured idle RSS is 7 MB and whose committed budget is under 30 MB.
Caddy's v2 read-body timeout defaults to unlimited, so the shipped proxy does not cover this either.
The team plainly holds these bounds as necessary; the HTTP path just never got them.

Secondary, in the same shape: `attachments::upload` takes `Bytes(body): Bytes`, which is `FromRequest` and therefore resolves last, so the body is fully read before `enforce(Class::Upload)` and before the ATTACH_FILES check.
Disk is still protected (the write happens after both gates, and `DefaultBodyLimit::max` bounds the buffer at the operator's ceiling).
What is not protected is memory and bandwidth for a caller who is over budget or holds no ATTACH_FILES bit at all.

Shape: give the HTTP surface the bounds the socket surface already has, and move the upload charge into a `FromRequestParts` extractor so it runs before the body is read - the trick `RateLimited<C>` already uses.
**Closed 2026-07-30, PR #145**, both halves, plus the eight uncharged routes: `AuthedLimited<C>` declares the class in the signature so "charges nothing" is visible to a reviewer, and `class_of` is exhaustive so a new class cannot silently inherit a looser budget.

## Safety features that do not do what the UI says they do

### 3. Blocking filters nothing in a shared channel, while two snackbars promise the messages are hidden - high

`client/packages/app/lib/src/features/channels/screens/channel_message_actions.dart:191`, `client/packages/app/lib/src/features/members/widgets/member_actions.dart:60`

The block list has exactly four app-side readers, all inside one settings widget (`personal_account_sections.dart:26,98,136`), and `blocksProvider` is `autoDispose`, so it is alive only while `BlockedSection` is mounted.
Nothing in the transcript, the message row, the member pane, the pinned list, search or the sync controller reads it.
The server hands the job over deliberately and says so at `store/safety.rs:200`: the client filters, the server does not strip.
The copy claims otherwise in three places, including "Blocked. Their messages are hidden for you."

One correction worth carrying forward, because the first reading of this was wrong: blocking is **not** inert.
`store/dms.rs:38` denies SEND, ADD_REACTIONS and ATTACH_FILES both ways, and `dms.rs:116,252` check `has_blocked` in both directions, so a block genuinely stops a DM opening and stops new content in an existing one, enforced server-side.
The unfiltered surfaces are shared channels: messages, reaction tallies, typing, presence, and the member row.

Who has to be able to do what: nobody needs a privilege.
The harmed party is the user who blocked someone, and the mechanism is that they are told they are protected and stop looking for another remedy.
This is worse than an unimplemented feature: the capability handshake advertises the deployment as offering block, and `docs/ROADMAP.md:117` records the Phase 2 criterion as met, so nothing in the project's own record would catch it.

Shape: a block-list provider that outlives the settings pane, filtering at read time where server content becomes UI, and if any surface is deliberately left unfiltered, saying so in the copy instead of the blanket claim.
**Closed 2026-07-30, PR #147**, in that shape, with two additions the shape did not anticipate. Reaction tallies and push cannot be filtered client-side at all - the wire carries a reaction count with no reactor ids, by design, and a notification is on the device before any filter runs - so both are filtered server-side per viewer, which keeps them view choices rather than moderation actions. And read state has to keep counting a blocked author, or a channel whose newest message came from one stays lit as unread forever. Presence and the member row are the surfaces left deliberately unfiltered, and the copy now names them.
An adversarial review of that fix found three more, none of which any test caught: the live `reactions.changed` broadcast was fanning one unfiltered tally to everybody (the store filter was right; the *event* was the problem, and it now carries ids only with the tally derived per receiving connection); the command palette runs a second message search that went unfiltered, and had no test coverage at all; and refetching the block list on every `sessionProvider` change made routine access-token rotation a race that could silently undo a just-confirmed block. See `CLAUDE.md`'s blocking section for all three and for why gating the transcript on the list having loaded was tried and reverted.

### 4. Sign-in shows a tick for any server that returns an identity object, which is not what the widget says the tick means - medium

`client/packages/app/lib/src/features/auth/screens/sign_in_screen.dart:272`

`ServerIdentityChip`'s own doc comment (`onboarding_shell.dart:282-288`) states the contract: "The tick is about the pinned fingerprint rather than about reachability - reaching a server says who answered, not that it is the one you trusted last time."
The call site passes `confirmed: version.identity != null`.
It renders as a bare accent check glyph with no semantic label, so it is also invisible to a screen reader.
Nothing on that screen reads the pinned key at all.

Who has to be able to do what: any server, including an attacker's, satisfies the condition with its own keypair.
It appears at the moment the user is deciding whether to type a password, next to the Space name and host, where a check mark reads as "verified".
The nearby fingerprint step is careful about what TOFU does and does not protect; this undoes that care, and it violates the widget's stated contract rather than a judgement call.

Shape: either compare against the pinned key and give a mismatch a distinct louder state, or drop the glyph - and label it either way.

## Trust in the connection itself

Three findings here, all client-side, all in the same three entry points, and they compound: the paths a returning user actually takes are the paths with no scheme rule, no fingerprint comparison and no address reduction.

### 5. The pinned server key is compared only when someone re-opens the manual connect dialog - medium

`client/packages/app/lib/src/features/auth/widgets/server_identity_confirmation.dart:30`

`confirmServerIdentity` has one call site: `onboarding_screen.dart:109`, inside `_manualFlow`.
Sign-in validates shape only and commits (`sign_in_screen.dart:161-177`).
The invite dialog pops straight through (`onboarding_screen.dart:229`).
The official-server button parses and goes (`onboarding_screen.dart:87`).
Relaunch runs `restoreSession`, which by its own doc "only reads local storage, never the network".
`models_identity.dart:8-11` documents the opposite of what ships: pinned on first connect and "compared on every one after".

The comparison is not absent - `server_identity_confirmation.dart:51` does compare, and the changed-identity step is reachable - but only by walking "Join a different Space", then "Connect to a Space", then retyping the address.
It never runs at connect time.

Who has to be able to do what: someone able to answer for that host after the first connect, which is the only window TOFU was ever meant to cover.
Users who joined by invite or by the official-server button have no pin recorded at all, which also leaves `docs/STRATEGY.md:367`'s claim that invite links carry an identity fingerprint unimplemented on the client.
Medium rather than high because `STRATEGY.md:351` is explicit this was never sold as an active-MITM defence.

Shape: bind the check to connecting rather than to address entry, pin on first connect from the invite and official paths, and keep "too old to report an identity" passing through.

### 6. The https-over-the-internet rule exists only in the manual dialog - medium

`client/packages/app/lib/src/features/auth/screens/sign_in_screen.dart:161`

The rule appears once, at `onboarding_screen.dart:335`, guarded by a well-defined `isLocalAddress` covering localhost, `.local`, 127/8, 10/8, 192.168/16 and 172.16/12.
`_submit` on the sign-in screen has no scheme test before it persists the address.
The invite dialog's entire validation is `hasScheme` plus a non-empty host.
No test pins the rule even in the dialog that enforces it.

Who has to be able to do what: anyone who can get a user to type or accept an `http://` public address, including via an invite link, and anyone on the path afterwards.
Sign-in is where the username and password are typed, and `router.dart:47-50` makes it where every signed-out user lands, so the one screen that transmits credentials will send them in cleartext without a word while the screen that transmits nothing refuses to.

Shape: one shared validator called from all three entry points, with the LAN exemption preserved untouched.

### 7. The SFU URL from the server is joined without requiring wss - low

`client/packages/app/lib/src/providers/voice_controller.dart:169`

`token.url` comes verbatim off the wire (`models.dart:219`) and is handed to `room.connect` as given (`voice_session.dart:178`), with no scheme check in any of the three files.
The server explicitly permits plaintext (`voice/mod.rs:367` accepts `ws://` and `http://`, and `voice/tests.rs:152` exercises `ws://10.0.0.100:7880/`).
The API client, by contrast, derives its own socket scheme from its own base URL (`client.dart:83`).

Who has to be able to do what: an operator who sets `SLIMM_LIVEKIT_URL` to the `ws://` LAN address because that is what worked, then publishes the deployment.
A user who reached the API over https then has signalling and media crossing the network in clear with nothing on screen saying so.
Low because it needs a misconfiguration and the server is already trusted for message content in this threat model; what is beyond that model is that the server can point a client's microphone and screen-share stream at an arbitrary third-party host.

Shape: treat the SFU URL like the server address, and make a plain-ws call a visible non-retryable state rather than a silent join.

### 8. Sign-in persists the typed address verbatim, keeping userinfo that dart:io turns into a Basic auth header - low

`client/packages/app/lib/src/features/auth/screens/sign_in_screen.dart:177`

The file documents the hazard at lines 81-84 and applies the reduction in `_probeTarget` (lines 90-94), then `_submit` does not.
The comment is correct on native: dart:io builds the header from userinfo (`http_impl.dart:2328,2331`).
`Uri.replace` keeps userinfo and query, and overwrites rather than appends the path, so a server mounted under a subpath is also silently rewritten to the root.

Who has to be able to do what: a user pasting or autofilling `https://user:pass@host`, on the one screen where a password is being typed.
Those credentials then land in the key store and ride every subsequent request as an ambient header the app never intended to send.
The base-path overwrite is a plain functional bug in the same line.

Shape: reduce the address on commit the way the probe already does, or refuse userinfo and say why, and decide deliberately whether a base path is supported.

### 9. Request paths are interpolated unencoded into `Uri.replace`, which resolves dot segments - low

`client/packages/api/lib/src/client_transport.dart:21` (and `:84`)

There is no `encodeComponent` or `pathSegments` use anywhere in `packages/api/lib` or `packages/app/lib`, and wire-supplied values are interpolated directly: `'/messages/$messageId/reactions/$emoji'` (`client_messages.dart:118,132`).
Confirmed against Dart rather than assumed: `.replace(path: '/messages/abc/reactions/../../account')` yields `https://chat.example/messages/account`, and `%2e%2e` resolves identically.

This is low, and the reachability analysis is worth recording so it does not get re-filed as exploitable.
The server accepts any 64-byte emoji string (`store/reactions.rs:65`), leaving about 58 characters of target.
DELETE is unreachable through the chip because the method comes from `reaction.reacted`, true only for a reaction the viewer created, and a reaction whose PUT landed elsewhere never gets created.
Every body-free PUT that fits needs a JSON body the reaction call does not send, and `PUT /roles/{role_id}/members/{user_id}` needs two UUIDs and does not fit.
`router.dart:145` interpolates a URL-supplied `channelId` with no length cap on web, which is a wider version of the same shape, and no harmful target exists there either.

Who has to be able to do what: today, nobody usefully.
The point is that the method and path a request lands on stop being decided by the calling code and start being decided by content, and the two things keeping it safe are a length constant in the server crate and the absence of a body-free PUT - neither of which this file controls.
`client_messages.dart:105-112` shows escaping here was thought about (colons) and dot segments were not, so this is an incomplete guard rather than an unexamined one.

Shape: encode at the single choke point in `_send` and `_fetchBytes`, with a test that a reaction string containing `../` still produces a request under the reactions path.

## Authorization boundaries inside a deployment

### 10. An attachment reference is an existence check, not an authorization decision - medium

`crates/slimm-server/src/store/attachments.rs:249`

`link_attachments` is the entire authorization on a reference, and its only predicate is `WHERE EXISTS (SELECT 1 FROM attachments WHERE sha256 = ?)`.
`attachments` (`migrations/0002_core_schema.sql:157-164`) has no uploader column, so there is nothing to check against even if the handler wanted to.
`http/messages.rs:466-469` states the contract out loud: whether the id names something *uploaded* is checked later - uploaded, not reachable.
Fetch then derives permission from the reference set the caller just created (`http/attachments.rs:161-176` allows the read if VIEW_CHANNEL holds in any referencing channel).
A miss returns 400, a hit 200.

Who has to be able to do what: any member holding SEND_MESSAGES plus ATTACH_FILES in any one channel.
That gives them the exact oracle `http/attachments.rs:178-184` refuses to build, in its own words: "a 403-versus-404 split would tell them whether those exact bytes were shared in a DM or a private channel they cannot see."
Worse than the oracle, on a hit they now hold a reference, so they can fetch the bytes and the stored filename.
It also bypasses revocation: a member who saw an id and later lost VIEW_CHANNEL re-links it into a channel they can still post in.
And it defeats the sharer's delete, since `release_message_attachments` frees the file only when nothing else references it - which is precisely what `tests/attachments/binding.rs::deleting_a_message_releases_its_attachment` exists to guarantee.
No test in `binding.rs`, `serving.rs` or `uploading.rs` constrains who may link an id.

Shape: pass the sender's id into `link_attachments` and require upload ownership or existing view access, with the refusal indistinguishable from "never uploaded" or the oracle just moves.

### 11. MANAGE_ROLES has an upward-reach guard and no downward one - medium

`crates/slimm-server/src/http/roles.rs:192`

`unassign` is gated on the bit alone, with no comparison of caller to target.
`assign`, twenty lines above, does check the granting direction.
`update` validates only the *requested* bits against the caller and never the role's current bits, so PATCHing a role the caller does not hold down to a subset of their own passes.
`delete` checks the bit alone.
The store adds only a structural invariant (`administrator_count == 0` refusals), which is about the deployment, not the actor.
The module doc scopes its guards to "everywhere a permission set becomes grantable" - revoking is not named, so nothing records this as deliberate, while `http/members.rs:264-289` implements exactly the missing rule for the moderation routes and explains why.

Who has to be able to do what: a member holding MANAGE_ROLES and nothing else.
Downgraded from high because `grantable` blocks every upward path, so they can never mint themselves ADMINISTRATOR.
What they can do is strip ADMINISTRATOR from every administrator down to the last one, and strip MANAGE_SERVER, BAN_MEMBERS or MANAGE_CHANNELS from peer moderators, one request at a time - permissions they do not hold and could not grant.
With two ADMINISTRATOR-bearing roles, the PATCH path also goes through, because the count guard is satisfied via the other.
`tests/roles.rs` covers the count invariant and nothing about actor level.

Shape: lift `members.rs`'s target-level check into a shared guard and apply it to unassign, update and delete, reading granted rather than effective permissions for the reason `members.rs` gives.

### 12. Voice kick is the one KICK_MEMBERS call site with no actor-versus-target check - low

`crates/slimm-server/src/http/voice.rs:210`

The handler checks the caller's own VIEW_CHANNEL plus KICK_MEMBERS and passes the target straight to `remove_participant`, with no level comparison and no self-check.
The durable act backed by the same bit is wrapped in `members.rs`'s `authorize`, which refuses both.

Who has to be able to do what: a member granted KICK_MEMBERS through a channel overwrite alone can eject an administrator from that channel's room on demand.
Not an access breach - the route's own doc comment notes a kick does not stop the target asking for a new token, and both sides are Class::Write limited - but it is a griefing loop against someone strictly senior, and it is the only consumer of that bit where the no-reaching-above-your-level rule is not applied.

Shape: reuse the same target-level guard so the rule holds for every consumer of KICK_MEMBERS.

## Resource ceilings, and the rate-limit charge that is opt-in

Two specialists reached this independently - one auditing authorization, one auditing input and DoS - which is why it sits here as one entry rather than four.
`Class::Write`'s own doc comment names mark-read as an example, and mark-read does not charge it.
There is no rate-limit layer on the router (`http.rs:97` applies only `TraceLayer`), so the charge is a line per handler, and the drift is invisible.
This project has already found and fixed exactly this defect once: the phase 3 audit recorded that `PATCH .../messages/{id}` charged nothing while send and delete both did.

| Route | File:line | Consequence beyond the missing charge | Severity |
|---|---|---|---|
| `POST /sync` | `http/sync.rs:143` | Amplifies one request into hundreds of sequential queries | medium |
| `PUT /channels/{id}/read` | `http/sync.rs:106` | `seq` validated against 0 and nothing else | medium |
| `POST /invites` | `http/invites.rs:147` | Grows `invites` with no ceiling, feeding an uncapped `GET /invites` | medium |
| `DELETE /invites/{code}` | `http/invites.rs:193` | Takes the single write lock per call | medium |
| `DELETE /devices/{id}` | `http/safety.rs:87` | Revokes sessions and publishes `SessionRevoked` per session | low |
| `POST /auth/logout` | `http/auth.rs:222` | Write plus a publish | low |
| `DELETE /account` | `http/auth.rs:235` | The heaviest multi-table write in the store, plus a publish per session | low |
| `GET /version`, `GET /healthz` | `http.rs:129,185` | The only unauthenticated endpoints with no bucket at all | low |

Two of these carry a second defect worth naming separately.

**`POST /sync` amplification - medium.**
Per scope the loop pays roughly ten sequential queries (five for the permission evaluation, then latest-seq, messages, reactions, attachments, polls) against an 8-connection pool.
The floor any member can reach is about 400 sequential round trips per request: 200 scopes of nonexistent UUIDs still cost two queries each, because `granted_in_channel` returns early but `timeout_deny` still runs as the argument to `.remove()`.
The frequently quoted ~2000 figure needs 200 distinct channels the caller can actually view, which a small self-host does not have, and should not be carried forward.
`MAX_SCOPES`, `AGGREGATE_LIMIT` and `SNAPSHOT_GAP` bound one response's size; nothing bounds request rate, and the per-scope permission evaluation happens before any of those caps apply.

**`PUT .../read` marker - medium.**
The upsert is `MAX(last_read_seq, excluded.last_read_seq)`, so one `{"seq": 9223372036854775807}` pins that channel's marker at `i64::MAX` permanently and its unread count reads 0 forever, with no later value able to lower it.
Self-inflicted only, since the marker is per (user, channel), but it is a field the handler bothers to validate and then does not.
The client also calls this route on every channel render, so it is a hot unthrottled path into the single SQLite writer.

Shape for the group: charge each of these a class, and make the recurrence structurally impossible with a mutating-method layer that reads opt out of, rather than a line each handler has to remember.
Clamp `seq` to the channel's current latest.

### 13. No storage quota anywhere, and the orphan grace window outlasts the time it takes to fill the volume - medium

`crates/slimm-server/src/store/attachments.rs:33`

`ORPHAN_GRACE_MS` is 24 hours, the sweep runs hourly with `ORPHAN_SWEEP_BATCH = 500`, `Class::Upload` allows 0.05 uploads/sec sustained, and the default per-request cap is 10 MiB.
There is no per-account or deployment-wide byte ceiling; grepping `quota|total_bytes|max_total` finds nothing, and `Media` carries only `max_attachment_bytes`.

Who has to be able to do what: one account holding ATTACH_FILES.
At the sustained rate that is about 1.76 GB/hour of never-attached bytes per account, none of it eligible for reclamation for 24 hours - roughly 43 GB before the sweep may even look - and the sweep's 500 rows/hour cannot catch up.
Content addressing does not help, since a valid header plus a random tail hashes differently every time.
Attaching the bytes to a message makes them permanent and exempt from the sweep entirely.
`deploy/README.md:43-46` already tells the operator Litestream does not cover these bytes, so disk is the exposed resource and there is no signal about it.

Shape: a deployment-wide byte ceiling checked before the write in the three upload paths, and a grace window a long way under 24 hours - the constant's own doc comment already calls it generous.

**Closed 2026-07-30, PR #151**, in that shape with one correction to it: there are not three upload paths to bound, there are two.
Avatars never enter the `attachments` table at all - `write_avatar` goes to its own directory, one file per account overwritten in place - so their total is already bounded by the member count times 2 MiB, no upload can grow it, and the `SUM(size)` the ceiling is checked against cannot see them. Counting them would need a second mechanism to bound something already bounded. Emoji does go through `store_attachment`, so it counts, though it was already bounded at 500 x 1 MiB behind MANAGE_SERVER; the unbounded vector is specifically `POST /attachments` behind deployment-wide ATTACH_FILES.
`SLIMM_MAX_TOTAL_ATTACHMENT_BYTES` defaults to no ceiling, because the right number is the operator's disk and a guess would either refuse a legitimate upload on a large volume or do nothing on a small one; the shipped compose stack sets 2 GiB so a self-host following the guide gets one. Past it, a 507 rather than a 413, so a screenshot tells an operator whose problem it is. The grace window is two hours.

### 14. Unbounded reads and per-row permission evaluation - low to medium

Four sites where the codebase's own established pattern was not applied.
The batched machinery already exists (`store/permissions_batch.rs`, `roles_for_users`, `timed_out_among_until`, `reactions_for_messages`), which is what makes these look like omissions rather than choices.

| Site | File:line | What it does | Severity |
|---|---|---|---|
| `GET /reports` | `http/reports.rs:82` | One six-query visibility evaluation per open report, no pagination, no cursor, no limit | medium |
| `GET /presence` | `http/presence.rs:81` | One single-row query per requested id, up to 100, unthrottled | low |
| `GET /channels/{id}/pins` | `http/pins.rs:119` | Every pin returned with no cap, over a thing with no per-channel pin ceiling | low |
| `viewers_among` DM branch | `store/permissions_batch.rs:63` | Fetches the DM pair once *per candidate*, and two comments assert it does not | low |

`GET /reports` needs MANAGE_MESSAGES to trigger, and the one-open-report-per-pair constraint keeps a friend-group deployment well under the numbers that hurt, which is why it is medium and not high.
The queue's ceiling is still reporters times subjects, and both the query count and the response body (a reason plus a content snapshot per row) grow linearly in something members control, while every other list in the API is bounded - messages 100, sync 500, canvas 2000, members 200.

The `viewers_among` entry is filed for the comments rather than the cost.
It is not on the send path - `PushSender::notify_message` hands the whole thing to a detached `tokio::spawn` - and N is push-registered users on a self-host, so N indexed single-row lookups is negligible.
The defect is that both comments state the loop is bounded at two real checks when it is one query per candidate, so the next contributor will believe it and look elsewhere.
Worth resolving `channel_viewer_ids` (`permissions_batch.rs:21`) in the same pass: it feeds every live account into that function and has no caller anywhere in `src/`, so it is a loaded gun rather than a live bug.

**Closed 2026-07-30, PR #148**, all four, with one correction and one choice worth naming.
The correction: `GET /presence` was never an unbounded read - it already capped its batch at 100 and documented that in the schema. What it lacked was any rate-limit charge at all, which puts it with findings 1 and 2's family rather than this one; it takes the Read class now.
The choice: `/channels/{id}/pins` is bounded at the **write** rather than paged at the read. A channel holds at most 200 pins and pinning past that is a 400, so every reader can still have the whole set, which is what a pin is for; a `limit` exists for a caller that wants fewer. `/reports` is genuinely paged, forward on a composite `(created_at, id)` cursor, because its ceiling is reporters times subjects and a moderator needs to work through a backlog.
The queue's per-channel filter moved into the `WHERE`, ahead of the `LIMIT`, which is the part worth recording: filtering after the limit made a short page mean either "some of that window was restricted" or "the queue ended", with nothing in the response telling them apart, so a moderator denied MANAGE_MESSAGES in one busy channel stopped paging with readable reports still ahead of them and a wholly restricted first window read as an empty queue. Pre-filtering also drops the per-report evaluation the finding was actually filed for: four queries for the whole page instead of six per row. The cursor is composite for the same reason - `created_at` is milliseconds, and a timestamp-only cursor skipped every remaining member of a tied group a page boundary fell inside, permanently.
`channel_viewer_ids` is deleted rather than documented, and `live_user_ids` with it: that was its only caller, and its own doc comment existed to explain the dead path.

## Hardening details

### 15. `POST /auth/reset` pays a full Argon2id hash before the reset code is looked at - low

`crates/slimm-server/src/http/recovery.rs:84`

The handler validates the new password, hashes it, and only then calls `consume_reset_code`, whose claim is a single conditional `UPDATE` on an indexed column that could run first.
Every attempt with a garbage code costs 19 MiB and one of only four Argon2 permits, held across the blocking hash.
`register` in the neighbouring module deliberately gets this right and says so in its doc comment (`auth.rs:99`), so the ordering rule already exists in this codebase and this route does not follow it.
Low on its own - the code is 256 bits, the acquire timeout bounds permit hold time, and the Password bucket throttles it - but that bucket is global behind the shipped proxy, so finding 1 and this one together mean a handful of requests can saturate the permits legitimate logins need.
There is no timing argument against reordering, since the endpoint answers unknown, expired and used identically anyway.

**Closed 2026-07-30, PR #145**, with one correction: there *is* a timing argument, just not a blocking one. A live code now answers visibly slower than a dead one, where before both paid the hash. That distinguisher is acceptable because a code is 256 bits, so anybody who can read it already had to guess a live code, and `recovery.rs` says so rather than glossing it. The answer itself stays uniform across unknown, expired and used.

### 16. Moderation reason fields carry no length cap while the report reason does - low

`crates/slimm-server/src/http/members.rs:134` (and `:193`)

The only bound is the module's 4 KiB body limit; neither the store nor the handler caps the string, and `GET /members/removed` hands it back verbatim for every removal in force.
`http/safety.rs:26` caps the report reason at 2000 chars.
Both routes need KICK_MEMBERS or BAN_MEMBERS, so there is no attacker here.
The value is consistency in a codebase that caps every other free-text field explicitly (message 4000, poll question 300, topic 256, search 200, display name 64, push token 1024), and a length contract a client rendering a removal list can design against.

**Closed 2026-07-30, PR #151.** One shared `validate_reason` at the same 2000, called from the report intake and both moderation verbs, with `required` the only thing that differs - a report must say why, a timeout need not.
Worth recording what writing it exposed: mutating the length check killed only the new moderation test and nothing in `tests/safety.rs`, so the report reason's own cap had been there all along with no test behind it. There is one now.

## What I would do first

1. **Fix the unauthenticated availability pair (findings 1 and 2) together.**
Both are reachable by anyone who can open a socket, both take a handful of requests, and one of them takes login offline for the whole deployment on the exact topology the owner runs.
They also share a fix surface (the proxy config plus one router layer), and the socket path already proves the team holds these bounds as necessary, so there is no design question to settle first.

2. **Make blocking do something in shared channels, or change the copy (finding 3).**
It is the only finding where the product tells a user they are protected and they are not, and it is one of exactly two safety tools this product ships.
The capability handshake advertises it and the roadmap records the criterion as met, so no existing gate will ever catch this.
Filtering at read time is contained client work; the alternative, honest copy, is one afternoon.

3. **Make the attachment reference an authorization decision (finding 10).**
It re-opens, from a route nobody audited, the precise existence oracle that `GET /attachments/{id}` has a written refusal to build, and it hands the caller the bytes rather than merely the answer.
It also quietly breaks two things the codebase believes it guarantees: revocation of view access, and an author's delete unsharing their file.
It needs a schema decision (an uploader column) so it is the one of the three that will not get smaller by waiting.

Immediately behind those: the rate-limit charge should stop being opt-in per handler rather than being fixed eight times.
That single layer closes seven findings at once and is the only thing that stops this same defect being found by a third audit.

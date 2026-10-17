<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Security and safety review: threads, replies, DM calling, the report queue, drag-to-reorder, display-name reconciliation, the live thread event, and clipboard (2026-08-02)

Scope: everything that shipped in the last two days (2026-08-01 and 2026-08-02), the seven surfaces named in the task plus the client clipboard plugins.
One real finding, and it is more severe than the task's own framing suggested: banning or timing out a member does not remove them from a DM call already in progress, because the pre-existing eviction routine was never taught about DM voice when DM calling shipped.
Blocking has the same gap in its milder, self-service form.
Everything else checked here holds, including several places that looked like they might not on first read.
No authentication bypass, no cross-channel information leak, no permission escalation, and no gap in the moderation containment rules the report queue reuses.

This is not a from-scratch audit of the whole codebase.
It is targeted at what changed in the window named above, read against the patterns the rest of this codebase already established (appear-offline's structural per-connection derivation, per-viewer reaction tallies, DM blocking enforced server-side, permission containment on moderation, LiveKit tokens as bearer credentials the server cannot revoke, timeouts as a subtraction at read time).
Where a new surface follows one of those patterns correctly, this says so and cites the code that proves it, rather than re-deriving the pattern's own case for existing.

## 1. Removal, timeout, and blocking all fail to end a DM call already in progress - high for removal/timeout, medium for blocking

`crates/slimm-server/src/http/members.rs:282-304` (`evict_from_voice`), `crates/slimm-server/src/http/safety.rs:145` (`block`), `crates/slimm-server/src/store/safety.rs:167` (`block_user`)

Calling in a DM (`6823474`, PR #306) added `CONNECT` and `SPEAK` to both `DM_BASE` and `BLOCKED_DENY` in `crates/slimm-server/src/store/dms.rs:38-56`, and `dm_permissions` (`store/dms.rs:262`) checks blocking, timeouts, and DM membership live, on every call.
That closes minting a *new* voice token: `http/voice.rs:101` requires `CONNECT`, so removal, a timeout, or a block placed before either party joins - or after one leaves - correctly refuses the other side from joining or rejoining.

What none of the three close is the same problem the rest of this codebase already named and fixed twice: a LiveKit token is a bearer credential the server cannot revoke, so a permission subtraction only reaches someone already in a room if something explicitly calls `remove_participant` for them.

**Removal and timeout - the more serious half.** Both routes call `evict_from_voice` (`members.rs:287-304`) after committing the moderation act, and its doc comment says "Drops a member from every voice room, best effort."
It does not.
It calls `state.store.list_channels()` and filters to `c.kind == "voice"` (`members.rs:288,295`), and `list_channels` (`store/bootstrap.rs:131-138`) excludes `kind != 'dm'` by its own query - a DM is never in the list this function iterates, regardless of whether the target is on a call in one.
`evict_from_voice` was added in PR #136 (2026-07-29, `git log -p -- crates/slimm-server/src/http/members.rs`, commit `1474ef8`), a full three days before DM calling gave a DM channel anything to evict someone from.
At the time it was written, "every voice room" and "every channel of kind voice" were the same set, because a DM could not carry `CONNECT`.
PR #306 changed that set without anyone revisiting this function, so its own doc comment has been wrong since the moment DM calling shipped, silently.

The severity here is real, not theoretical: `BAN_MEMBERS`-driven removal is documented elsewhere in this project as "a ban in behaviour" - "they are signed out and cannot sign in again."
A member removed while mid-DM-call with a third, unrelated party keeps that call running exactly as it was, with no code path anywhere that would end it, until the call ends on its own or one side hangs up.
The same is true of a timeout, which is meant to be an immediate silencing.
Reachable by anyone holding `KICK_MEMBERS` or `BAN_MEMBERS` (subject to the existing containment check), against any two other members having a DM call the moderator is not even part of.

**Blocking - the milder, self-service version of the same gap.** `block` (`http/safety.rs:145`) only inserts a row into `user_blocks` and returns; it never looks up a live DM room and never calls `remove_participant`.
Client-side, `blockUser` (`client/packages/app/lib/src/features/members/widgets/safety_actions.dart:73`) goes through `blocksProvider.notifier.block`, which only mutates the local block set and calls the same REST endpoint - nothing in that path touches `VoiceController` or the DM call pane.
This one is lower severity than removal/timeout because the blocker retains a full self-remedy: leaving the call ends it for both, since a DM call only ever has the two of them.
It is still worth fixing for the same reason: the code comment on `BLOCKED_DENY` (`store/dms.rs:47`, "a blocked person must not be able to ring or join a call any more than they can send a message") states an intent the mechanism does not carry out for a call already underway, even though the user-facing copy after blocking (`safety_actions.dart:80`, "Blocked. You will not see what they post.") does not itself overclaim.

Shape: `evict_from_voice` should evict from a target's live DM voice rooms too, not only `kind == "voice"` channels - the DM pair is one query away (`store/dms.rs` already has the lookup shape `dm_permissions` uses) - and `block_user` should call the same routine for the blocked pair specifically. Fixing `evict_from_voice` alone closes the removal and timeout cases; blocking needs its own call site added since it is not routed through `members.rs` at all.

## 2. Threads: permission resolution under the edge cases named in the task

`crates/slimm-server/src/store/permissions.rs:295` (`permission_channel`), `crates/slimm-server/src/store/threads.rs`

Checked each of the three cases the task names, by reading the actual queries rather than trusting the module doc comments' claims about them.

**Parent message deleted after the thread exists.** `permission_channel`'s lookup of the parent channel (`permissions.rs:302-307`) is `SELECT channel_id FROM messages WHERE id = ?`, with no `deleted_at` filter.
So a thread whose parent message is later soft-deleted keeps resolving to the same parent channel and the same overwrites; the thread does not silently fall back to `@everyone` or become unreachable.
That matches the design (a thread's permissions are the parent *channel's*, not a property of the parent message staying live) and there is no path here where a soft-deleted parent either opens a hole or wrongly closes one.

**Parent channel deleted.** `Store::channel` (used inside `permission_channel`) filters `deleted_at IS NULL`, so once the parent channel is gone, `permission_channel` returns `None`, and every caller of it (`evaluate_channel_permissions`, `viewers_among`) treats `None` as "deny" rather than falling back to the thread's own (nonexistent) overwrite bucket - the same fail-closed choice the doc comment on `permission_channel` states. Verified by reading `permissions.rs:295-312` and `permissions_batch.rs:54-57` directly; both discard channel and return no permissions when this resolves to `None`.

**An overwrite changed after the thread was created.** `evaluate_channel_permissions` (`permissions.rs:319-345`) queries `channel_overwrites` live, on every call, with no caching beyond the WebSocket's shared `permissions_epoch` (which `Hub::publish` bumps before every event, deployment-wide, not per-channel - see the "Caching a permission on the socket" section of `CLAUDE.md`). An overwrite change on the parent is picked up by the next check against the thread exactly as it would be for the parent itself, and the epoch invalidates any cached WS permission entry the moment the overwrite-changing request publishes, regardless of whether the cached entry was keyed by the parent's id or the thread's.

**Nesting.** `open_thread` (`store/threads.rs:78-92`) checks the *channel's* `parent_message_id`, not the message's own `reply_to_id`, before allowing a new thread - correctly distinguishing "this message lives in a channel that is itself a thread" (refused) from "this message is a reply to another message" (irrelevant to nesting, since a reply does not create a channel). Confirmed against the query directly; the `OpenThreadError::NestedThread` path is reachable only through that channel-level check.

**Cross-channel message id.** `open_thread`'s existence check (`store/threads.rs:78-84`) requires `m.id = ? AND m.channel_id = ?`, so a caller who holds `SEND_MESSAGES` in one channel cannot open a thread naming a message id from a channel they cannot view - the message lookup itself fails rather than falling through to a permission check on the wrong channel.

## 3. Every enumeration site that should exclude a thread, checked by hand

Task's question: is there an enumeration site the 2026-08-01 pass missed - push fan-out, search, the report queue, the canvas, invites?

- **`list_channels`** (`store/bootstrap.rs:131`) and **`reorder_channels`**'s own copy of the live-channel query (`store/channel_order.rs:64-67`) both filter `parent_message_id IS NULL`. Confirmed by reading both queries; they are separate literal queries (not one calling the other), which is exactly the duplicate-query shape `CLAUDE.md` already flags as this project's recurring bug pattern, and both were in fact given the filter.
- **`delete_channel`'s last-channel guard** (`store/channels.rs:242-253`) counts `WHERE deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL`, so a deployment holding threads on its one real channel cannot have that channel deleted while the guard still reads "more than one." The row being deleted is not itself excluded from `kind != 'dm'` targeting, so `DELETE /channels/{id}` can target a thread directly - this is by design (`CLAUDE.md`: "there is deliberately no UI for deleting a thread specifically... the generic DELETE route already reaches one"), gated on deployment-wide `MANAGE_CHANNELS`, not a gap.
- **Push fan-out** (`viewers_among`, `store/permissions_batch.rs:43-57`) applies the same `permission_channel` substitution before branching on DM vs. role/overwrite evaluation, so a reply landing in a thread whose parent is a DM correctly narrows push recipients to the DM pair rather than falling through to the role-based branch. Read directly; this is not merely asserted by the module doc, the substitution happens before the `channel.kind == DM_CHANNEL_KIND` check.
- **Search** (`http/search.rs:53-67`) is per-channel, gated on `has_permission(channel_id, VIEW_CHANNEL)` for the `channel_id` in the URL path, which resolves through the same live permission machinery. A thread's own channel id is searchable by anyone who can view the parent, and (since UUIDv7 ids are not guessable and there is no channel enumeration that reveals thread ids to a non-viewer) there is no path to search a thread whose id you do not already legitimately know.
- **Reports** (`store/channels.rs:99-122`, `channel_scopes_moderation`) returns `false` for a thread the same way it does for a DM, routing per-channel moderator visibility to the deployment-wide fallback rather than a per-channel `MANAGE_MESSAGES` check that would mean nothing for a channel with no overwrite bucket of its own.
- **Canvas.** `open_thread` seeds a `canvas` stream counter for every thread channel the same as any channel (`store/threads.rs:125-132`), so a thread channel is technically canvas-capable, and `USE_CANVAS` on it resolves correctly through the same `permission_channel` substitution as every other bit. The client-side `CanvasOpenButton` lives in `ChannelHeader`/`CompactChannelAppBar`, and `ThreadScreen` (`client/packages/app/lib/src/screens/thread_screen.dart`) wraps `ChannelScreen` in its own plain `AppBar` rather than routing through either of those - but `ChannelScreen` itself conditionally renders an inner `ChannelHeader` when `layout.showsBothPanes` is true (`channel_screen.dart:265-273`), which is a width-based layout decision independent of the screen's own navigation context. On a wide window this likely means a thread opened as a pushed route also renders the parent's `ChannelHeader`, including a canvas button, inside the thread's own AppBar. This did not turn up any permission problem - a thread's canvas access correctly resolves to the parent's `USE_CANVAS` bit either way - so it is a product surprise (an extra canvas surface nobody asked for) rather than a security finding, and is not rated further here.
- **Invites** grant deployment-wide join plus a role; they have no channel dimension to leak a thread through.

## 4. Replies cannot be used to learn about a message you cannot read

`crates/slimm-server/src/store/messages.rs:171-187`

A reply's `reply_to_id` is checked server-side against the *sending* channel: `SELECT channel_id FROM messages WHERE id = ?`, and the send is rejected with `SendError::InvalidReplyTarget` unless that channel equals the channel the reply is being sent into (`messages.rs:176-187`).
A nonexistent parent id and a parent id that exists in a different channel produce the identical error, so there is no existence oracle across channels.
Since the reply itself can only be sent by someone who already holds `SEND_MESSAGES`/`VIEW_CHANNEL` in that same channel, and UUIDv7 ids are not guessable, there is no way to use a reply to confirm a message exists in, or learn anything about, a channel you cannot already view.

Only `reply_to_id` (the parent's own id) is ever on the wire (`http/message_dto.rs:29-31`); no parent content is denormalized onto the reply.
Client-side, the reply quote is resolved purely from messages already loaded into the same permission-gated transcript (`widgets/message_transcript.dart:301`, "built from the same already-filtered list this transcript renders"), never through a second fetch that could reach past what the viewer is authorized to see.

## 5. The report queue's quick actions reuse the dedicated moderation routes exactly

`client/packages/app/lib/src/screens/admin/report_card_actions.dart`, `crates/slimm-server/src/http/members.rs:259-280`

This PR (#304) is client-only - it added no server route and no server-side authorization logic.
Confirmed against the diff (`git show 2733e0d --stat`): every file it touched is under `client/`.
`deleteReportedMessage`, `timeOutReportedAuthor`, and `removeReportedAuthor` call `SlimmApi.deleteMessage`, `.timeOutMember`, and `.removeMember` - the same three endpoints the dedicated moderation screens already call, so the containment check (`authorize` in `members.rs:266-280`, comparing *granted* permissions, caller must contain target) and the self-target refusal (`caller == target` at `members.rs:272`) apply identically whether the call originates from the report card or from the member popover.
`delete` (`http/messages.rs:221-259`) is gated on per-channel `MANAGE_MESSAGES`, the same bit that determines whether a report is even visible to this moderator in the first place (`channels.rs:99-122`), so there is no route by which a report surfaces a delete action for a channel the moderator cannot otherwise moderate.

The one thing worth checking specifically for a report-derived action is whether the *target* of timeout/remove could be spoofed by whoever filed the report, rather than by the server's own record of who authored the reported message.
It cannot: `subject_author_id` (`store/reports.rs:74,169,208`) is derived server-side from `m.author_id` via a join on the actual message row, never taken from the reporter's request (`file_report`, `http/safety.rs:181-229`, accepts only `subject_kind` and `subject_id` - a message or user id, never an author id).
Client-side, `report_card.dart:169-171` sets `targetUserId` from `report.subjectAuthorId`/`report.subjectId`, which is this server-derived value, not the reporter's id (`report.reporterId`, rendered separately and never fed into an action).

## 6. Drag-to-reorder channels holds under the obvious abuse attempts

`crates/slimm-server/src/http/channel_order.rs`, `crates/slimm-server/src/store/channel_order.rs`

Gated on deployment-wide `MANAGE_CHANNELS` (`channel_order.rs:47-55`), the same bit `createChannel`/`updateChannel`/`deleteChannel` already require.
`reorder_channels` (`store/channel_order.rs:58-104`) refuses any list that is not exactly the current live, non-DM, non-thread channel set (`live_set != given_set`, `channel_order.rs:74`), inside one `BEGIN IMMEDIATE` transaction from the first read, so there is no way to smuggle a DM id or a thread channel id into the position ordering, and no window for a concurrent create/delete to land between validation and write.
This closes the two obvious abuse paths: naming a channel the caller cannot view (impossible without already knowing its id, and the exact-set check would reject an incomplete list anyway since the full live set is required), and a race between two admins dragging concurrently (serialized by the write-lock transaction, and a no-op submission publishes nothing per `channel_order.rs:39-40`, so this does not add fan-out noise on every drag).

## 7. Display-name reconciliation (`Event::ProfileChanged`) is consistent with the existing public-profile model, not a new leak

`crates/slimm-server/src/http/ws/authorization.rs:136-140`, `crates/slimm-server/src/http/users.rs:1-9`

`ProfileChanged` is delivered deployment-wide and unconditionally (`authorization.rs:113-141`), unlike `PresenceChanged`, which resolves a per-viewer answer.
That looks, on first read, like the kind of unfiltered fan-out this codebase's own history warns about (the `ReactionsChanged` tally bug, the appear-offline model).
It is not: `http/users.rs`'s own module doc states the design directly - "Every profile returned here is the narrow public shape only: id, username, display name, and creation time" - and `GET /users`/`GET /members` already serve that shape to any authenticated deployment member with no per-channel or block check.
`ProfileChanged` carries only a user id, no name and no other field, so the event itself discloses nothing beyond "this id's public profile changed," which is strictly less than what the existing `/users` route already hands any member on request.
It does not reveal online status (unlike `PresenceChanged`, which is deliberately per-viewer for that reason) and blocking a user does not remove them from the member list by design (`CLAUDE.md`'s blocking section: "the person stays in the member list where the block can be undone"), so an unconditional eviction-only event naming their id is consistent with an already-public surface rather than a new one.

## 8. The live thread event's permission gate

`crates/slimm-server/src/http/ws/authorization.rs:56-85,162-168`, `crates/slimm-server/src/http/threads.rs:88-116`

`Event::ThreadUpdated` requires only `VIEW_CHANNEL` (`extra_bit` returns `None` for it, `authorization.rs:66`), keyed on the *parent* channel's id in both publish sites: `open` publishes with the caller-supplied `channel_id` (`http/threads.rs:73-75`, already checked for `VIEW_CHANNEL`+`SEND_MESSAGES` before this point), and `notify_reply` publishes with `parent.parent_channel_id` resolved via `Store::thread_parent` (`http/threads.rs:109-115`), which itself calls `permission_channel` (`store/threads.rs:166`) rather than trusting the thread channel's own (nonexistent) overwrite bucket.
Since a thread's permissions always resolve to the parent's by construction, gating on the parent id directly (rather than the thread's own id, which would evaluate identically through the same resolution) is not a shortcut that skips anything - it is the same answer reached one hop earlier.

On the argument for carrying `reply_count` directly rather than deriving it per-viewer the way `ReactionsChanged` derives its tally: checked against `Store::thread_summaries_for_messages` (`store/threads.rs:189-228`), which is what a REST fetch of the same page already uses, and that query counts every undeleted reply with no blocking predicate.
So precomputing the count into the live event matches what a fetch already answers; it does not introduce a new inconsistency, only carries forward one that already exists on the REST path (a thread reply from a blocked author already inflates the count on a plain fetch).
That pre-existing behavior is outside this review's two-day window and is already named in `CLAUDE.md`'s own note on the same feature, so it is recorded here as confirmed rather than as a new finding.

## 9. Clipboard plugins: nothing reaches Dart beyond the pasted image itself

`client/packages/app/android/app/src/main/kotlin/top/npcserver/slimm/ClipboardImageChannel.kt`, `client/packages/app/ios/Runner/ClipboardImagePlugin.swift`, `client/packages/app/ios/Runner/ClipboardPasteBridge.m`

All three surfaces expose exactly two questions to Dart (`hasImage`, a boolean; `readImage`, raw bytes) plus, on iOS, a third boolean reporting whether a native method swizzle installed.
No filename, no source-app identity, no other clipboard item, and no metadata beyond image presence crosses the channel.

- **Android** (`ClipboardImageChannel.kt:45-64`) reads `ClipboardManager.primaryClip`'s first item's `content://` URI through the app's own `ContentResolver`. This is standard platform-mediated clipboard access (Android's own URI-permission auto-grant governs whether the read succeeds at all) and does not read or expose anything the OS was not already willing to hand this app.
- **iOS direct read** (`ClipboardImagePlugin.swift:41-52`) is a plain `UIPasteboard.general.image` call, which raises Apple's own "Allow Paste?" consent prompt on every call (confirmed on a real device per the file's own comment) - there is no route here that reads the pasteboard without that OS-level gate.
- **iOS edit-menu swizzle** (`ClipboardPasteBridge.m`) replaces two methods on Flutter's private `FlutterTextInputView` using a donor class (`SlimmPasteDonor`) rather than a category, specifically to avoid a link-time reference to a private engine symbol - this is a build-safety concern documented in the file itself, not a security one. The swizzled `paste:` only fires from inside iOS's own dispatch of the system paste gesture (the documented exemption from the consent prompt), reads `UIPasteboard.generalPasteboard.image`, and hands PNG bytes to a single static callback (`sOnImage`) registered from Dart. If the class or selector lookups fail, the function returns `NO` and installs nothing (`ClipboardPasteBridge.m:100-139`) - there is no partial-swizzle state where one half is patched and the other is not.

Whatever bytes arrive from either platform flow into the same `stage`/`_stageAttachment` callback (`composer_clipboard_paste.dart:52-59`) every other picked-file attachment already uses, so they are subject to the same client- and server-side size and content-type checks as any other upload - this is not a parallel, less-audited upload path.
Filenames are hardcoded (`'pasted-image.png'`), so there is no path traversal or filename-injection surface here.

## What I would fix first

One item, and it is worth doing promptly rather than filing away: teach `evict_from_voice` (`members.rs:287-304`) about DM voice rooms, so removal and timeout actually end a call the way their own documentation already claims they do.
That single fix also gives blocking something to call for its own, lower-severity version of the same gap.
Everything else in this review held under the specific abuse cases the task named, including several (the thread nesting refusal, the reorder exact-set check, the report queue's server-derived target id) that would have been real findings if they had been missing.

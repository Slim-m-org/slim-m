# 0011 - Per-channel permissions

Date: 2026-08-09.
Status: ~~designed, not built~~ built 2026-08-09 (PRs #517, #518, #522); status line corrected 2026-08-11 by the full-stack review, which found it still claiming design-only a fortnight after the code shipped.

`docs/reports/screen-review/README.md`'s systemic finding names one missing abstraction behind seven independent bugs: the client gates actions on the caller's deployment-wide base permissions (`GET /me`, `myPermissionsProvider`), while the server authorizes the same actions per channel (`Store::permissions_in_channel`).
There is no per-channel effective-permission route on the server, and no such provider anywhere in the client.
`/me`'s own OpenAPI description already says its bitmask is "a UI nicety only," which is the honest reason all seven sites exist: the client was never given the thing it would need to do better.
This record designs that thing.

## What already exists, checked against the real code

The hard part is already built and does not need reinventing.
`Store::permissions_in_channel` (`crates/slimm-server/src/store/permissions.rs`) already resolves a thread to its parent through `permission_channel`, branches to a wholly different evaluator for a DM through `dm_permissions`, and subtracts a timeout at read time.
Any new server surface should call this function, not reimplement any part of it.

`Store::channels_where` (`crates/slimm-server/src/store/permissions_batch.rs`), which backs `GET /channels` through `visible_channels`, already computes the full per-channel `Permissions` bitmask for every channel it evaluates.
It calls `evaluate(...).remove(timeout_deny).contains(needed)` and keeps only the boolean.
The bitmask itself is thrown away.
`hidden_channels` in `crates/slimm-server/src/http/reports.rs`, which filters `/reports`, does the identical thing a second time: it calls `channels_where(user_id, Permissions::MANAGE_MESSAGES)` and keeps only channel-id membership in a `HashSet`.
Both are real, and both matter to this design, but neither is a substitute for a dedicated route: `channels_where` only ever walks `Store::list_channels()`, which excludes DMs and deleted channels by construction (see `docs/decisions/0005-threads.md`), so it structurally cannot answer for exactly the two channel-having report cases the flagship bug (site 7 below) is about.

Live events already exist for most of what would go stale.
`Event::RoleChanged`, `Event::MemberRoleChanged`, `Event::MemberTimeoutChanged`, and `Event::OverwriteChanged` are all in `hub.rs`'s `moves_permissions` match and all bump `permissions_epoch` on publish.
`OverwriteChanged` carries only the channel id and is gated by the *current*, post-change `VIEW_CHANNEL` check, so a caller who loses a channel-scoped bit (say `MANAGE_MESSAGES`) while keeping `VIEW_CHANNEL` is told immediately; the event's own doc comment names the one gap it does not close, a caller whose `VIEW_CHANNEL` itself is revoked receives nothing, which is an accepted, already-documented gap this design does not need to re-solve.
The one genuinely unannounced change is a timeout lapsing: `crates/slimm-server/src/store/timeouts.rs`'s own module doc says this "expires by arithmetic," nothing runs and nothing is published, so no cache invalidated purely by events can ever be told a timeout just ended.

One adjacent gap, found while tracing this: `client/packages/app/lib/src/features/members/providers/member_presence.dart`'s `memberModerationWatcherProvider` already listens for `MemberTimeoutChanged` and invalidates `membersProvider` (the roster), but nothing anywhere invalidates `meProvider` on that same event for the caller's own account.
`meProvider` is only invalidated on sign-in/sign-out (`sync_controller.dart`).
So today, if a moderator times themself out of relevance mid-session (or, more realistically, is timed out by someone else while their client stays open), their own `myPermissionsProvider` reading stays wrong until the next unrelated `meProvider` refetch.
This predates the per-channel work and is not one of the seven sites, but the fix for the new provider's identical failure mode is one line in the same listener, so it should land in the same change rather than being left as a second, un-fixed instance of the exact bug this record exists to close.

## The five things that decide the shape

**1. The report queue needs an arbitrary channel it is not looking at, on a page mixing many channels, no channel, and deleted channels.**
`/reports` is already filtered per channel before the limit (`hidden_channels`, described above), gated additionally on deployment-wide `MANAGE_MESSAGES` just to enter the route at all.
Its own doc comment explains why the filter is a complement rather than an allow-list: a report with no channel, one about a DM, and one about a since-deleted channel must all stay visible on the caller's base bit alone, because none of the three appears in `list_channels`.
That means a report's `channel_id`, when present, does not by itself say whether the caller can currently manage it: it could be a DM (never manageable, by design), a deleted channel (nothing to manage), or a live channel the caller already has `MANAGE_MESSAGES` in (or the report would have been filtered out).
The client cannot tell these apart from what `ReportDto` carries today, so this needs a value computed server-side, batched per page, not a per-card lookup.

**2. A thread reached by URL is in neither `GET /channels` nor `GET /dms`, and gets no local channel row at all.**
`ChannelDto`'s own doc comment in `crates/slimm-server/src/http/channels.rs` says "a thread never appears in `listChannels`," and `docs/decisions/0005-threads.md` confirms this is deliberate, not an oversight.
`shell.md` records that this also means the client never gets a local `channels` row for such a thread, so any design that leans on a locally cached channel to seed its permission read is exactly wrong for this case.
The fix is that a per-channel permission read has to work cold, keyed only on the channel id, with no dependence on the id having shown up in any prior list response.
`permission_channel`'s own thread-to-parent resolution already makes this safe: asking about the thread's own id is enough, the same way `messages.rs` and `pins.rs` already ask about a thread's own id and get the parent's answer back.

**3. `GET /channels` already runs a batched evaluation; check whether it is thrown away.**
Confirmed above: yes, in `channels_where`.
Carrying the already-computed bitmask forward costs nothing extra query-wise, it is a change to what one closure returns, not a new query.
But because it only ever walks `list_channels()`, it only ever helps for an ordinary, already-visible, non-DM, non-thread channel, which is the one case that needed this the least (the caller is already looking at it).
It is a genuine free win for the common path and nothing more; it does not substitute for a dedicated route.

**4. A permission can change while a screen is open, and a timeout lapse has no event.**
Covered above.
The design answer is: use the live events that exist (surgical, per-channel invalidation for `OverwriteChanged`; broad invalidation for `RoleChanged`/`MemberRoleChanged`/self `MemberTimeoutChanged`), and explicitly accept the one gap that has no event, the same way the server's own `OverwriteChanged` doc comment names its own accepted gap rather than solving it.

**5. Three client traps.**
Addressed directly in the provider design below, since each is a shape choice, not a separate mechanism.

## Recommendation: the wire shape

### A new route: `GET /channels/{channel_id}/permissions`

Response body: `{"permissions": <i64>}`, the same single-field shape `MeDto.permissions` already uses.
Rate-limit class: `Class::Read`, matching `GET /channels` and `GET /reports`; this is a plain authenticated read with no larger cost than any of the `has_permission` calls already scattered through the write paths.

Behavior: call `permissions_in_channel(caller, channel_id)`, which already handles thread resolution, the DM branch, and the timeout subtraction.
Then mask the whole answer to zero whenever the result lacks `VIEW_CHANNEL`, regardless of what other bits `evaluate()` happened to produce.

That masking is not caution for its own sake, it closes a real leak this design would otherwise introduce.
`granted_in_channel` forces `Permissions::NONE` for a channel that does not exist, specifically so a probe against a fabricated id cannot be told apart from a real channel the caller cannot view.
But a caller's *base* permissions are not zero in the ordinary case (`@everyone` usually grants something), and a real channel with no overwrite touching those bits passes them straight through unchanged.
So a route that returned the raw bitmask verbatim would answer differently for "channel does not exist" (forced `NONE`) than for "channel exists, caller cannot view it, but no overwrite happens to deny the bits their base already grants."
That is a channel-existence oracle, the exact class of leak `/sync` already goes out of its way to avoid (`http/sync.rs`: "silently skip scopes the caller cannot view, so sync never confirms a hidden channel exists").
Masking on `VIEW_CHANNEL` closes it, because none of the seven sites, or any consumer this record anticipates, ever needs a bit without `VIEW_CHANNEL` also being true: every one of them is scoped to a channel the caller is already looking at, or to a report already filtered server-side.
No separate 403/404 branch is needed either, matching `overwrites.rs`'s own stated precedent of refusing "no such channel" and "not permitted here" identically.

### A field on `GET /channels`: `ChannelDto.permissions: i64`

Populated from the bitmask `channels_where` already computes and currently discards inside its filter closure.
Free: no new query, only a change to what that closure returns.
Every row `visible_channels` returns already has `VIEW_CHANNEL` by construction (`visible_channels` is `channels_where(VIEW_CHANNEL)`), so this field never needs the masking rule above.

This field is for a different question than the dedicated route answers: not "what can I do in the one channel I have open," but "which of my channels can I do X in," asked over the whole visible set at once.
The one site that actually needs that shape is site 2 below (whether to show the "Channel permissions" settings row at all).
Asking the dedicated route once per visible channel just to decide whether to show a settings row would be exactly the N+1 this record exists to remove; the list-wide field is the only cheap way to answer it.

### A field on `GET /reports`: `ReportDto.channel_permissions: i64 | null`

`null` exactly when `report.channel_id` is `null`.
Computed once per page, not per report, by a new batched store function, `Store::permissions_in_channels(user_id, &[ChannelId]) -> HashMap<ChannelId, Permissions>` in `permissions_batch.rs`, sibling to `channels_where` and `viewers_among`.

This cannot be `channels_where` reused as-is, because `channels_where` only ever walks `list_channels()`'s live, non-DM set, and the two report cases that most need this value, a DM and a deleted channel, are both outside that set.
The new function has to accept an explicit id list (the distinct channel ids named by the current page, bounded by page size, at most 50 in the default page) and branch per id: `permission_channel`'s thread resolution for a thread id, `dm_permissions` for a DM id, `Permissions::NONE` for a deleted or nonexistent id, and the ordinary role/overwrite evaluation, batched the way `channels_where` already batches it, for everything else.
On a real page, the thread and DM branches touch a small minority of ids; the shared cost, one `load_roles` call and one `IN`-batched overwrite query, is paid once for the whole page regardless.
Masked the same way as the dedicated route, for the same reason.

One case is worth naming explicitly because it is where the design earns its keep: a DM's `DM_BASE` always carries `VIEW_CHANNEL`, so a DM report's `channel_permissions` is never masked to zero, it passes through as `DM_BASE` (minus `BLOCKED_DENY` if either party has blocked the other), which structurally never contains `MANAGE_MESSAGES`.
That is not a special case in the client, it is the same masked-or-not answer every other channel gets, and it is exactly what fixes the sharpest finding in the review: a DM harassment report's "Delete message" button reading as available when the server can never grant that permission to anyone in a DM.

Two alternatives were considered and rejected for this field:

- **The client calls the dedicated single-channel route once per distinct channel id on the page.** Rejected: it is a real N+1, only bounded rather than eliminated, it adds a second round trip after the page has already arrived, and it regresses the exact discipline this codebase already applies to this exact class of problem elsewhere (`channels_where`, `viewers_among`, both built specifically to remove a per-item query loop over "many channels, one caller").
- **Generalize `hidden_channels` itself to return the bitmask instead of membership.** Rejected: `hidden_channels` only ever asks about `list_channels()`'s domain plus threads it resolves by hand; it structurally never asks about a DM id or a deleted id, which are precisely the two cases site 7 needs answered.

### `GET /dms` gets no new field

The DM message-action menu's need (site 1) is served by the dedicated single-channel route, called with the DM's own channel id, the same way a thread is called with its own id.
Hardcoding `DM_BASE` client-side to skip that call was considered and rejected: it would be a second authority over `dm_permissions`'s one fact, the same shape `docs/decisions/0009-reactions-pins-polls-reconciliation.md` already argued against for a different feature, and a local mirror of a constant like `BLOCKED_DENY` would silently drift the day the server-side set changes without every client build picking it up.

### Route naming and schema

`GET /channels/{channel_id}/permissions` follows the existing nested-route convention (`/channels/{channel_id}/overwrites/...`, `/channels/{channel_id}/canvas/ops`, `/channels/{channel_id}/read`).
`crates/slimm-server/tests/openapi_contract.rs` fails the build the moment a route exists in the router but not in `schema/openapi.yaml`, so the schema edit has to land in the same change as the route, not after it.

## The client seam

`channelPermissionsProvider = FutureProvider.autoDispose.family<int, String>((ref, channelId) => ...)`, calling the new route through `apiProvider`, mirroring `invitesProvider`/`rolesProvider`'s own shape and doc comment: nothing here is long-lived state, a screen refetches on entry.

It always calls the network route, uniformly, for every channel id, whether or not that id also happens to be present in a locally cached `ChannelDto`.
This was a real choice, not the obvious one: seeding from the cached `ChannelDto.permissions` field when available would save a request for the common case, but it would also mean the provider has two sources of truth for the same fact depending on which channel it is asked about, which is the shape this codebase has already decided against once (`docs/decisions/0009`'s "a second authority over one fact is the seam the canvas's own module doc names as its worst residual").
One source, one path, at the cost of one extra small `GET` per channel per screen-open, the same cost every sibling provider in `admin_providers.dart` already accepts.
`ChannelDto.permissions` still earns its place, but for a different consumer (the list-wide question in site 2), not this one.

Default value: `0` while loading or on error, the identical convention `myPermissionsProvider`'s own doc comment already states ("every gate here reads as show nothing until proven otherwise").
A synchronous derived `Provider<int>` sits on top, `ref.watch(channelPermissionsProvider(channelId)).valueOrNull ?? 0`, the same relationship `myPermissionsProvider` already has to `meProvider`, so every call site gets a plain `int` to check `.hasPermission` against, no `AsyncValue` handling duplicated at each of the seven sites.

Lifetime and invalidation: `autoDispose`, and:

- `RoleChanged`, `MemberRoleChanged`, and `MemberTimeoutChanged` where `event.userId == self` all call `ref.invalidate(channelPermissionsProvider)` bare on the family, which invalidates every currently-watched instance, the same blast radius `roleChangeWatcherProvider` already applies to `meProvider` for the first two.
  This is the same listener, extended by one more event, not a new one, and it is what closes the pre-existing `meProvider`-self-timeout gap named above in the same change.
- `OverwriteChanged{channel_id}` calls `ref.invalidate(channelPermissionsProvider(channelId))`, one line, surgical, new case in the same listener.
- A timeout lapsing on its own gets no event and gets no new mechanism.
  This is a stated, accepted gap, not an oversight: the server always re-authorizes the actual write regardless of what the client's cached bitmask says, so the cost of staleness here is a button that offers an action and then fails, for a bounded window closed by the next natural refetch trigger (leaving and reopening the screen, or any of the events above), never a security gap.
  It is the same rhetorical move `OverwriteChanged`'s own doc comment already makes about its one known gap, applied to this one.

Reading it avoids the three named traps:

- **Cold `autoDispose` read in a callback.** All thirteen existing `myPermissionsProvider` call sites already use `ref.watch` inside a widget's `build()`, none of them read it once in a callback; the fix at each of the seven sites is a substitution at that exact same call site, `ref.watch(myPermissionsProvider)` becomes `ref.watch(channelPermissionsProvider(channelId))`, so the trap CLAUDE.md records (a *new* picker sheet introducing a fresh synchronous read) does not reproduce here, because none of these seven currently do that.
- **A drift `StreamProvider` hang.** Does not apply; this is a plain `FutureProvider` over one HTTP call, no drift table, no stream, matching `docs/decisions/0009`'s own precedent that a value this shape (small, re-derivable, not independently paged) belongs in Riverpod memory, not a local table.
- **Riverpod in the canvas paint path.** `canvas_pane.dart`'s `build()` already reads `meProvider` and passes a plain `bool` (`canManage`) down through `CanvasPaneBody` as a constructor parameter, never into a `CustomPainter`.
  The fix swaps the source provider and keeps the same plumbing, so the "no Riverpod call reaches the canvas paint loop" invariant `canvas.md` already confirmed holds is untouched.

## Per-site verdict

1. **`channel_screen.dart:278`, DM/thread message-action menu (`myPermissionsProvider`).** Convert.
   `ref.watch(channelPermissionsProvider(widget.channelId))` replaces `ref.watch(myPermissionsProvider)` at this one call site; it already threads into `messageActionsFor` as the same plain `int myPermissions` parameter that function already takes, so `channel_message_actions.dart` needs no signature change, only a different value fed in from its one caller.
2. **`space_settings_section.dart:100-105`, "Channel permissions" row.** Partially convert.
   The section's overall visibility gate (`spaceSettingsReachable`) stays on base permissions for `manageMessages`/`createInvite`/`manageServer`/`manageChannels`/`banMembers`, all genuinely deployment-wide actions (`roles.rs`, `members.rs`'s own module docs both say so directly).
   The "Channel permissions" row specifically should show if the caller holds `manageRoles` either at the base level or via a channel overwrite in at least one visible channel, which the new `ChannelDto.permissions` field answers directly (`myVisibleChannels.any((c) => c.permissions.hasPermission(Perm.manageRoles))`), closing the under-offering half of this bug (a caller with `MANAGE_ROLES` only via one channel's overwrite currently has no way to reach the screen that would let them use it).
   `channel_overwrites_screen.dart:178`'s own doc comment ("there is no endpoint to read that per-channel figure, so this uses the base set as a safe, possibly stricter, stand-in") is now wrong once the dedicated route ships and should be updated to read the real figure via `channelPermissionsProvider` once a channel is picked, replacing its own documented workaround rather than leaving it as stale prose beside working code.
3. and **6. `member_profile.dart:287-305`, member popover.**
   Mixed, on purpose, at the level of the individual action, not the file.
   `canTimeOut` (`kickMembers`, deployment-wide timeout) and `canRemove` (`banMembers`) and `canManageRoles` (`manageRoles`) stay on `mine` (base), because `members.rs`'s own module doc says both timeout and removal are deployment-wide by design, and role assignment is deployment-wide the same way site 2's does.
   `canEject` converts: it gates a per-room voice kick, `voice.rs`'s `kick` handler checks `permissions_in_channel(caller, voice.channelId)` specifically because "a caller who holds `KICK_MEMBERS` only through a channel overwrite may still hold nothing deployment-wide" (the handler's own comment), so this becomes `ref.watch(channelPermissionsProvider(voice.channelId!))`, guarded by the same `voice.channelId != null` check already there.
4. **`channel_message_actions.dart:217-259`, `messageActionsFor`.** Same fix as site 1: it is fed by its one caller (`channel_screen.dart`), so converting site 1 converts this too, with no change to `messageActionsFor`'s own signature.
5. **`canvas_pane.dart:369-370`, canvas context menu and "Clear canvas," plus a third call site in the same file this record's first pass missed: `_onErase`'s own local gate.** Convert all three.
   `ref.watch(meProvider).valueOrNull?.permissions` becomes `ref.watch(channelPermissionsProvider(widget.channelId))` at 369-370, read in the same `build()`, passed down as the same plain `bool canManage` constructor parameter, never touching the paint path.
   `_onErase` (around line 339) computed the identical base-bitmask boolean from its own fresh `ref.read(meProvider)` to decide whether an erase gesture may touch another member's stroke, gating a real write with the wrong bit for the same reason the menu did; it now `ref.read`s `myChannelPermissionsProvider(widget.channelId)` instead, safe as a read because `build()` already watches that same family instance every frame, so it is never a cold `autoDispose` read from a callback.
7. **`report_card.dart:159-181`, quick actions.** Mixed, at the level of the individual action.
   `canTimeOut` and `canRemove` stay on `mine`: `report_card_actions.dart`'s `timeOutReportedAuthor` and `removeReportedAuthor` call `timeOutMember`/`removeMember`, both deployment-wide per `members.rs`.
   `canDeleteMessage` converts to the new `report.channelPermissions` field (`report.channelPermissions?.hasPermission(Perm.manageMessages) ?? false`), closing the sharpest finding in the whole review: the DM report case now genuinely cannot offer a delete button, because `channel_permissions` for a DM report structurally never carries `manageMessages`.

Everything else that reads `myPermissionsProvider` (`role_editor_sheet.dart`, `role_assign_sheet.dart`, `invite_role_grant_picker.dart`, `member_roles_sheet.dart`, `command_palette.dart`, `space_menu_button.dart`) is gating role CRUD, role assignment, or invite creation, all confirmed deployment-wide in `roles.rs`'s own module doc ("every verb here is gated on MANAGE_ROLES at the deployment level, since roles are not scoped to any one channel"), and stays exactly as it is.

## What gets a test, and what mutation it would catch

Server, following `tests/permissions.rs`'s own equivalence-test convention:

- The new route returns the same bits `permissions_in_channel` would for an ordinary channel, including the timeout subtraction.
  Mutation: call `granted_permissions_in_channel` instead (skips the subtraction); a test asserting a timed-out caller's `SEND_MESSAGES` bit is absent from the route's answer would fail.
- Called with a thread's own channel id, it returns the parent's evaluated bits.
  Mutation: drop the `permission_channel` resolution; a test asserting the thread and its parent answer identically for the same caller would fail.
- A fabricated uuid and a real channel the caller cannot view, where the caller's base grants a nonzero bit no overwrite touches, answer byte-identically (both zero).
  Mutation: return the raw unmasked bitmask; this existence-probing test is the one this masking rule exists for and would fail immediately without it.
- Called against a DM channel id, the answer never contains `MANAGE_MESSAGES`, for any caller including one whose base carries `ADMINISTRATOR`.
  Mutation: skip the DM branch and fall through to the ordinary evaluator; this is the exact site-7 scenario and would fail on it directly.
- `Store::permissions_in_channels` (the batch function) answers identically, id by id, to calling `permissions_in_channel` once per id in the same fixture set (a no-channel id skipped, a DM id, a deleted id, and a live-permitted id together), mirroring the equivalence-test shape already used for `channels_where`/`viewers_among`.
  Query-cost is documented in the function's own doc comment, the same way `channels_where`'s is, not asserted by a query-counting test: this codebase's test suite has no query-counting harness today (checked; only row-count assertions of the `SELECT count(*)` shape exist), and a claim this record cannot verify a mechanism for should not be made as if it were tested.
- No new `openapi_contract.rs` test is needed; it already fails the build if the route exists without a schema entry, so the requirement is the schema edit landing in the same change, not a new test.

Client:

- A widget test asserting the DM message-action menu offers no Delete/Pin for `MANAGE_MESSAGES` even when the caller's base grants it, using a DM fixture and a fake `channelPermissionsProvider` answer that lacks the bit.
  Mutation: revert the call site to `myPermissionsProvider`; this test would fail on exactly that regression.
- `report_card_test.dart` gains a genuinely distinct "denied by permission" fixture, closing the gap the README itself names (`report-card-no-quick-actions-desktop.png` and `report-card-reporter-resolving-desktop.png` being byte-identical because neither test supplied a `channelPermissions` value), plus a DM-subject case.
  Mutation: revert `canDeleteMessage` to `mine.hasPermission(...)`; both would fail.
- A provider-invalidation test mirroring `roles_screen_test.dart`'s existing coverage of `roleChangeWatcherProvider`, extended to a self `MemberTimeoutChanged` case and a channel-scoped `OverwriteChanged` case, each proving the right provider entry is invalidated and, for the channel-scoped case, that unrelated channel ids are not.

Named honestly rather than smoothed over: the "watch, never a cold synchronous read in a callback" discipline itself has no automated guard anywhere in this codebase today, only the convention CLAUDE.md's existing note already states.
This record does not add one; it only avoids reopening the trap at the seven known sites by reusing their existing `ref.watch`-in-`build()` shape rather than introducing a new read pattern.
A future picker or sheet that reaches for this provider still needs the same manual care that note already asks for.

## Migration order

1. Server: the dedicated route (`permissions_in_channel` plus the `VIEW_CHANNEL` masking), its tests, and the `schema/openapi.yaml` entry, landed together and unused by any client build yet, the same additive-first shape `docs/decisions/0005-threads.md` used for the thread schema itself.
2. Server: `ChannelDto.permissions` (free, from `channels_where`'s already-computed value) and `ReportDto.channel_permissions` plus `Store::permissions_in_channels`, with the schema edit and equivalence tests in the same change.
   Still additive and unread by any shipped client.
3. Client: hand-add the new route method and the two new DTO fields to `client/packages/api` (`models_channel.dart`, `models_moderation.dart`, and wherever the channel-permissions call belongs) to match the schema; this client is hand-written against the schema, not generated, so this is a manual edit, not a codegen step.
4. Client: `channelPermissionsProvider`, its default-zero derived provider, and its two invalidation listeners (including the `meProvider` self-timeout fix), each with its own test, still unused by any of the seven sites.
   A pure addition; nothing can regress yet because nothing reads it.
5. Client: convert the seven sites one at a time, each its own small change with its own widget-test update, in the order above, since each conversion is a one-line provider swap at an existing call site rather than a new pattern.
6. Client: the two aggregate fixes that are not simple substitutions, site 2's row-visibility check against `ChannelDto.permissions`, and `channel_overwrites_screen.dart`'s stale "no endpoint" doc comment.
7. Leave every deployment-wide site untouched: role CRUD and assignment, invite creation, member timeout/removal, analytics.
   They already check the scope the server actually enforces.

Nothing is half-converted at any single commit in this order: steps 1-4 are pure additions with nothing depending on them yet, and each of steps 5-6 converts exactly one call site to a value that has already existed, and been tested, since step 4.

## What this record does not settle

Whether embedding `channel_permissions` on `ReportDto` is the right long-term trade against a separate batch route, if report pages ever grow well past the current 50.
The embedded field was chosen because it avoids a second round trip and reuses this codebase's own batching shape, but the new per-page store function's cost was not measured against a real dataset.

There is no query-counting test harness anywhere in this suite, checked rather than assumed, so the batched function's cost claim stays a doc comment the way `channels_where`'s already is, rather than something a test asserts.
(No longer true, and the doc comment it settled for was wrong: see the 2026-09-22 amendment at the end.)

## Amended 2026-09-22: there is a query-counting harness now, and the cost claim was wrong twice

Two statements above no longer hold: that this suite has no query-counting harness, and that `Store::permissions_in_channels` costs a bounded number of statements.

**The cost claim was wrong.** The doc comment this record deferred to said "one `channel` fetch per distinct requested id" as though that were the bound.
It is not a bound at all: `Store::send_message` reaches `may_link`, which hands `permissions_in_channels` *every* channel that has ever attached a given sha256, so the statement count grew with how far a file had travelled, on the message-send path.
The 2026-09-20 audit found it. Counted, with the per-id loop still in place: asked about 2 channels directly it cost 6 statements and about 24 it cost 28, and a whole `send_message` linking a file on 2 channels cost 13 against 35 for the same file on 24.
Batched, the same four measurements are 5, 5, 12 and 12.

This is the second time a comment here stated a bound that was not there - `viewers_among` did the same thing in July - which is the argument against settling a cost question in prose.

**So the harness exists now.** sqlx emits one `sqlx::query` tracing event per statement, so a subscriber counting those events counts statements.
It lives in `crates/slimm-server/tests/permissions_batch_cost.rs` and it has one real constraint worth knowing before reusing it: sqlite is synchronous, so sqlx runs each connection on a worker thread of its own and emits the event there.
A thread-local `set_default` subscriber therefore counts nothing, and a test built on one passes vacuously at zero - which is why that file installs a global subscriber, holds itself to a single test so nothing interleaves its counts, and asserts the counter saw sqlx at all before asserting anything about a number.

The resolution itself moved to `store/permissions_resolve.rs`: three rounds for the channel lookups whatever the id count, and one pair query plus two block reads for however many DMs are in the list.
The equivalence tests this record asked for still carry the correctness argument; the new file only carries the cost.

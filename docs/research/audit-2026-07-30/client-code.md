<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
## Client code

The client is the largest and least-gated part of the repository, and the shape of what the audit found reflects that.
There is no shortage of good shared components: `runGuarded`, `AppAsyncView`, `confirmDangerousAction`, `showAppSheet`, `AppCard`, `AppListRow` and the six-step type scale all exist, are documented, and in several cases carry a doc comment explaining the sweep that produced them.
What is missing is adoption and a gate: five of those six shared mechanisms are used by fewer call sites than the number of places that hand-roll them, so the componentisation work is mostly finishing sweeps that were started rather than designing anything new.
That matters beyond tidiness, because in four cases the hand-rolled copy has already diverged in a way a user can see, and in two cases the divergence is a defect the shared component exists to prevent.

Alongside that, seven confirmed defects reach a user today, and they cluster in two places: the message path (`message_store.dart` plus `message_transcript.dart`) and per-row State in keyless lists.
Two of them are latent only because no deployment here has accumulated 200 messages in a channel yet.
Two more are safety-relevant paths (removing a member, reporting a member) that cannot complete at all and are green in CI.

Findings below were produced by seven specialists working from different angles; where two or more of them arrived at the same thing independently that is noted, since it raises confidence.

---

### 1. The shared-mechanism register

This is the core of the componentisation opportunity.
Each row is one decision that has a home in the codebase, and the number of places that answer it somewhere else.

| Mechanism | Canonical home | Uses it | Hand-rolled | Drift that has already happened |
|---|---|---|---|---|
| Failure copy for a failed write | `runGuarded` / `GuardedActionState`, `widgets/run_guarded.dart` | 5 files | 24 write sites | 24 sites can render `POST /x failed: SocketException ...` to the user |
| Loading / error / empty over an `AsyncValue` | `AppAsyncView`, `design_system/.../surfaces/async_view.dart` | 6 sites | 13 sites in six shapes | two surfaces offer no retry at all; two use the client's only `LinearProgressIndicator` |
| Destructive confirmation | `confirmDangerousAction`, `widgets/confirm_dialog.dart` | 8 sites | 1 (account deletion) | the copy renders danger as a filled button, against a rule stated in three places |
| Sheet on a phone, dialog on a desktop | `showAppSheet`, `design_system/.../surfaces/sheet.dart` | 16 sites | 6 `showDialog` | the screen-share flow changes modal idiom between its two consecutive steps |
| Bordered content panel | `AppCard` | 9 sites | 16 hand-drawn | radius splits `card` (10) vs `control` (6) on surfaces one inch apart |
| Anchored popover (target/portal/follower/TapRegion) | none | - | 4 copies, identical comment | only one clamps to the viewport, only one closes on scroll, only one handles right-click |
| Focusable tappable thing | `FocusableTapTarget` (forms only) | 4 form widgets | 4 core/surface components | `AppMenuItem` gets no pressed state, no focus node and no haptic |
| Own-or-receive a `FocusNode` | none | - | 3 verbatim copies | a dead `= false` initialiser in each, overwritten one line later |
| Resolve `AppTokens` from context | none (`AppTokens.of` does not exist) | - | 154 sites | two sites the formatter breaks across three lines to fit |
| Form-sheet frame (padding, keyboard inset, scroll, title, error, submit) | none | - | 4 copies | sheet title is `AppText.body` (15px) in three and `AppText.heading` (20px) in three |
| Keyboard navigation over a highlighted list | none | - | 2 files, 3 duplicated pieces | the copy is acknowledged in a comment |
| Channel-by-id lookup | none | - | 4 copies, each opening its own `watchChannels()` | one spelled `firstWhere((c) => true, orElse: ...)` 55 lines from a `firstOrNull` in the same file |
| Channel kind wire strings | `dmChannelKind` covers `'dm'` only | 1 of 3 | 11 sites for `'voice'`/`'text'` | `initialKind` typed as bare `String`; `Channel.isVoice` exists and has no production caller |
| Author display label | three copies | - | 3 | a comment justifying two copies sits above one of three |
| Busy state on a button | absent from `AppButton` | - | 8 label swaps, 1 inner spinner, 1 tooltip swap | ellipsis is `...` in 15 places and `…` in 4 |
| Pane gutter for compact vs regular | `AppSizes.paneGutter*` | - | 7 ternaries in 4 files | the composer computes its predicate differently from the rows it says it matches |

**Failure reporting is the one to do first, and it carries a real defect.**
`client_transport.dart:44` throws `TransportException('$method $path failed: $e')`, and `TransportException extends ApiException`, so every `on api.ApiException catch (e)` that renders `e.message` can put a Dart exception string on screen.
`test/run_guarded_test.dart:36` is a committed test asserting exactly that this must not happen, and 24 write sites route around the function it covers.
The worst is `providers/voice_controller.dart:196`, whose stored string is rendered full-screen by `screens/voice_screen.dart:150`, so losing connectivity while joining a call shows a `SocketException` on the flagship feature.
`widgets/join_policy_row.dart:52` renders it seventeen lines above its own read path at `:76`, which carries the comment stating the opposite rule.
Two further sites drop the failure entirely rather than mis-wording it (below), and `widgets/media_capability_section.dart:103` interpolates a bare `Object?` into a settings callout.
Seen from four directions (messaging, people, screens, duplication passes), with counts re-derived each time; 24 is the verified figure.

**The 401/403 wording is inverted in the shared helper.**
`widgets/run_guarded.dart:39` attaches "you are not allowed to do that" to `UnauthorizedException`, and there is no `ForbiddenException` clause at all, so a genuine permission denial falls through to the vague default.
Every write behind the helper (member removal, role grants, invite revocation, un-removing a member) is permission-gated, so the common case gets the wrong sentence while a dead session gets a permissions explanation that signing in again cannot act on.

**`AppAsyncView` is used six times against thirteen reinventions in six shapes.**
Its own header records that a component-usage audit found five shapes across eighteen sites; there are still six.
Three near-verbatim copies each re-derive the "a 403 is not retryable" rule locally (`widgets/channel_search.dart:82`, `widgets/pinned_messages_sheet.dart:96`, `widgets/member_pane.dart:69`).
A fourth names it in private classes `_PickerError`/`_PickerEmpty` (`screens/admin/overwrite_target_picker_sheets.dart:117`) in a directory whose sibling screens all use the shared component.
Two error branches offer no way forward (`widgets/channel_rail.dart:124`, `screens/home_shell.dart:177`), and `widgets/personal_account_sections.dart:43` and `:109` render a failure as unstyled default-coloured body text beside the only `LinearProgressIndicator` in the client, in a file that imports `AppErrorState` and uses it 80 lines lower.
The one capability the copies have and the component lacks is a retryability predicate over the error.

### 2. Componentisation with a behavioural consequence

**`role_assign_sheet.dart` is the un-migrated twin of `member_roles_sheet.dart` and dropped its permission gate.**
`screens/admin/role_assign_sheet.dart:103` wires the toggle's `onChanged` unconditionally; its twin at `widgets/member_roles_sheet.dart:128` reads `myPermissionsProvider`, computes `grantable = mine.hasPermission(role.permissions)`, and shows "Needs permissions you do not hold" instead, with a comment saying it mirrors the server's refusal.
So a moderator holding MANAGE_ROLES but not the target role's own bits is offered toggles the server will refuse, and granting a role from the Roles screen behaves differently from granting the same role from the member profile.
The sheet also has no in-flight state, so the control appears to do nothing for a whole round trip; the rest of its divergence (hand-rolled catch, bare spinner, error with no retry, raw `ListTile`) is the same list the twin already fixed.

**Two identical image-pick prologues disagree about which iOS picker opens.**
`widgets/emoji_upload_card.dart:35` documents at length why it uses `FileType.custom`: on iOS `FileType.image` opens the Photos-backed picker, which cannot see a file that arrived by download, Files or a messaging app.
`widgets/avatar_settings_section.dart:32` uses `FileType.image`, so an iPhone user cannot set a saved picture as their avatar.
The injectable seam that would make the path testable exists (`emojiImagePickerProvider`) and was built for one of the two callers, which is why the avatar upload is asserted only up to "nothing was uploaded".

**The two server-identity screens drop the onboarding frame and hardcode the step count.**
`widgets/server_fingerprint_step.dart:110` and `widgets/server_identity_changed_step.dart:41` rebuild the `Scaffold`/`Center`/`SingleChildScrollView`/`ConstrainedBox(420)` frame by hand and print the literal `STEP 2 OF 3`, while `OnboardingShell` is that frame at maxWidth 480 and `OnboardingStepper` renders the count off `OnboardingStep.values`.
So adding a step makes the literal wrong in two places the enum cannot reach, the literal is invisible to the stepper's own `Semantics` label, and the one screen where a human is asked to decide something carefully loses the brand panel and changes measure relative to the steps either side of it.

**`ContextMenuRegion` has no production call site and is weaker than the copy that is used.**
`widgets/context_menu_region.dart:15` says it was extracted so any other row could offer the message row's interaction; `message_context_menu.dart` does not use it, nor does any member surface, and the only reference outside its own file is one test.
Against the message menu it lacks the viewport clamp, the scroll listener, the hover pin and the hold-progress tint, so a contributor who takes the doc at its word gets a menu that runs off the bottom of a phone and stays open through a scroll.

### 3. Correctness

Ordered by severity.

**`watchChannel` returns the oldest 200 rows, not the newest.**
`packages/data/lib/src/message_store.dart:25` orders `seq` ascending with `limit: 200`, and drift's `OrderingTerm` defaults to ascending; the index in `database.dart:117` is `(channel_id, seq DESC)` under a comment saying reads scan newest-first.
Nothing prunes local rows and history pagination does not exist, so once a channel passes 200 cached messages the transcript is pinned to the first 200 ever synced and every later arrival is invisible until a sign-out or a server reset.
`_markReadUpToLatest` then takes the 200th-oldest row as "newest", so the read marker and the unread badge freeze with it.
No test in `message_store_test.dart` passes a `limit` at all.
Found independently by the packages pass and the performance pass.

**A pending or failed send sorts to the top of the transcript.**
`packages/data/lib/src/database.dart:53` states that `seq` is zero while a message is only local "so pending messages sort last", and the ascending order makes zero sort first.
For a fast ack the window is invisible, but `markFailed` leaves `seq` at 0 permanently, so a failed send sits at the very top of the transcript carrying the Retry/Edit/Discard row that exists for it, while `_scrollToLatest` animates to the other end.

**Transcript rows carry no key, so an arriving message rebinds an open edit field and an open context menu.**
`widgets/message_transcript.dart:126` maps slot to message purely by position and passes no `key:`; only index 0 gets an identity.
In a reverse list each arrival shifts every row's index by one, so the element at a slot is rebound to a different message: `MessageEditField` seeds its controller once in `late final` (`message_edit_field.dart:29`) and is rebuilt fresh from stored content, discarding whatever was typed.
The open context menu is not closed by the arrival either (`_closeOnScroll` listens to `ScrollPosition`, which does not notify on a content-extent change at unchanged pixels), so Delete, Pin and Report act on a neighbouring message, and the item set reflows under the finger between press and tap.
Hover-reveal state moves the add-reaction affordance onto the wrong row by the same mechanism.
Nothing drives `MessageTranscript` in any test.
Found by the messaging pass and the performance pass independently.

**Three admin screens leave `_busy` true on the success path, and their keyless children hand that dead state to whichever row shifts into the deleted index.**
`screens/admin/roles_screen.dart:80`, `reports_screen.dart:77` and `emoji_screen.dart:87` clear the flag only inside the catch.
Their children are keyless (`_RoleCard(role: list[i])`, `_ReportCard(report: list[i])`, `_EmojiRow(emoji: item)`), the list really shortens on success, and `AppAsyncView` keeps the data branch mounted through the refresh, so the row sliding into the deleted index inherits a permanently-null Delete button with no indication why.
`removed_members_screen.dart:72` is the one that clears before branching.
The same latch shape without the keyless component appears in `widgets/poll_composer_sheet.dart:61`, `widgets/manage_channel_sheet.dart:69` and `:107`, and `widgets/create_channel_sheet.dart:53`, where a non-`ApiException` escape leaves the button reading "Sending..." forever; exposure there is narrow because `ApiException` is sealed and covers every server and network failure.
`GuardedActionState.actionError` is inheritable through a keyless list the same way `_busy` is.

**"Remove from Space" and "Report user" from the member profile always throw instead of acting.**
`widgets/member_profile.dart:364` calls `widget.onDone()` (a `Navigator.pop`, 180ms reverse transition) and then awaits a confirmation dialog before touching `ref`; flutter_riverpod 2.6.1 throws `StateError` from both `read` and `invalidate` after the element is disposed, and `runGuarded` catches only sealed `ApiException` subtypes, so it escapes as an unhandled async error.
`removeMember` has exactly one call site in the app, so there is no second route to removal.
`reportMember` has the same shape via the shared `run` helper at `:286`, and it is guaranteed to lose because it awaits a typed reason first.
"Message" (open a DM) is a timing race on the same helper and loses whenever the server is slower than the pop, which under reduce-motion is always.
Every mount in `test/member_profile_test.dart` passes `onDone: () {}`, which is why all of this is green in CI.

**No request timeout anywhere in the REST client.**
`packages/api/lib/src/client_transport.dart:42` and `:97` await `http.Response.fromStream` with no deadline, and Dart's `http.Client` sets none on either backend.
A server that accepts a connection and never answers hangs the caller for the life of the process; the reachable case is a mobile network transition, and the visible one is the onboarding invite dialog's spinner, which resets `_busy` only in a `finally` that cannot run.
The fix belongs in the shared transport, which is also why `_fetchBytes` matters (next).

**`_fetchBytes` is a hand-copy of `_send`'s transport, auth, 401 replay and error mapping.**
`client_transport.dart:86` repeats lines 20 to 64 in the same order, differing only in the success branch.
Any transport-level change has to be made twice, and a timeout applied to `_send` alone would leave the three byte-fetching routes unbounded with nothing failing to say so.

**Six of the fifteen live WebSocket frames are absent from `schema/openapi.yaml`.**
`ServerFrame.oneOf` at `schema/openapi.yaml:3871` lists nine; `ws.rs` serialises fifteen and `events.dart` parses fifteen.
`ReactionsChanged`, `MessagePinned`, `MessageUnpinned`, `PollVoted`, `MemberTimeoutChanged` and `MemberRemoved` are absent from `components.schemas` entirely.
`models.dart`'s own header tells the next contributor to treat the schema as the record, and the route-surface gates compare methods and paths only, so frames drift with nothing failing.
This is the half of the protocol a second client implementation would get wrong first.

**A base URL carrying a path prefix is silently discarded.**
`client_transport.dart:21` does `baseUrl.replace(path: path)`, which drops `/prefix`; all four address-entry sites validate only `hasScheme` and a non-empty host.
The server mounts every route at root with no strip-prefix, so subpath hosting is not a supported configuration - the defect is the silent drop and the wall of unexplained 404s, not a lost capability.

**The invite entry point reaches neither guard the manual one enforces.**
`screens/onboarding_screen.dart:94` passes the invite dialog's address straight to `onServerChosen`, while `:102` runs `confirmServerIdentity` first, and `server_identity_confirmation.dart:69` is the only writer of the trust-on-first-use pin.
So a server joined by invite is never pinned and a later key change on that address is never detected.
The invite dialog also validates only scheme-and-host where the manual dialog refuses non-https unless the address is local, so `http://chat.example` typed by hand is refused with an explanation and the same address pasted from an invite is accepted.
An invite is the one path where the address comes from somebody else, so it is where a wrong host is most likely.

**`deviceName` is the literal `'desktop'` on both sign-in paths.**
`screens/sign_in_screen.dart:189` and `:196`, with no other writer anywhere in the client.
Every session on the account is named "desktop", including a TestFlight iPhone, and the Devices list distinguishes rows only by `isCurrent`.
The screen exists so somebody can revoke the session on a phone they lost, and revoking the right one is a guess.

**The caller's own `/me` is fetched once per process and never again.**
`providers/providers.dart:211` is `FutureProvider.autoDispose`, pinned alive by the non-autoDispose `myPermissionsProvider`, and the only invalidations in the app are two avatar uploads.
A promotion or demotion by another admin never reaches the client, so a demoted member keeps offering delete/pin/roles until relaunch.
Sharper: signing out and in as a different account in one launch leaves account A's `Me` cached, so `meProvider.valueOrNull?.id` still reports A at four ownership-derived sites and A's bits still draw B's admin UI.
Everything is re-authorized server-side, so this is wrong UI rather than escalation.
There is no role-change event in `hub.rs` at all, so the session edge and the reconnect are the only available handles.

**Two writes in the account settings have no error handling at all.**
`widgets/personal_account_sections.dart:74` (`removeDevice`) and `:134` (`unblockUser`) throw out of an async `onPressed` with no try, so on failure the provider is never invalidated, the row does not change, and nothing reaches the user.
"Sign out this device" failing silently is the security-relevant one.
Neither has a test.
Separately, `blocksProvider` is a list of ids and `:131` renders each raw 36-character uuid where a name goes, which is the one thing `message_row_identity.dart:207` says reads as corruption rather than staleness.

**A failed presence change leaves the UI asserting a visibility the server never accepted.**
`widgets/presence_menu.dart:61` sets the local echo, and the catch shows a SnackBar without restoring it.
`presenceVisibilityDisplayProvider`'s own doc records that there can be no read-back (`PATCH /presence` echoes only what it set, `GET /presence` resolves the caller's own id to their true connection state), so nothing heals it short of a relaunch, and its stated rule is that every surface must render null as "no choice known" rather than asserting one.
The settings pane copies the body verbatim (`widgets/personal_status_sections.dart:48`) so the fix has to be made twice, and additionally does `value: selected ?? _options.first.$1` at `:43`, painting "Online" on every launch for someone who chose appear-offline.

**Image decode is uncapped everywhere in the client.**
No `cacheWidth`, `cacheHeight` or `ResizeImage` anywhere in `client/packages`.
Avatars are re-encoded to 512px on upload and drawn at 20, 26 and 64, so roughly 1 MiB of bitmap per member decodes to draw a 20px disc.
Attachments are stored and served as uploaded under a 10 MiB cap, so a phone photo can be 4000x3000 (about 48 MiB decoded) on the raster path inside a scrolling transcript.

**`messageExtrasProvider` copies an app-wide, never-pruned map per event, and the channel screen watches all of it.**
`providers/message_extras.dart:247` is `state = {...state, id: extras}`, `MessageExtras` has no value equality, and the provider has no autoDispose and no eviction, so it grows an entry for every message seen in any channel for the session and each of five call sites copies the whole thing.
`_hydrateExtras`'s 50-message fetch produces 50 successive whole-map copies (one coalesced rebuild, not 50).
Because `screens/channel_screen.dart:257` watches the map rather than a key, a reaction or poll tally anywhere in the app rebuilds the entire visible transcript.
Nothing drops an entry on `MessageDeleted`.

**The command palette's Messages group can never take you to the message.**
`widgets/command_palette_items.dart:115` navigates to `Routes.channel(message.channelId)`, and the group only exists when that channel is already open (the palette reads the id off the route and searches only that channel), so selecting a result re-navigates to where the user is and pops.
Nothing scrolls to or highlights the message, and `MessageTranscript` exposes no scroll-to-seq entry point.
A whole keyboard-reachable result group looks functional and reads as a broken Enter key.

**The palette also discards the futures from its result actions.**
`widgets/command_palette.dart:126` awaits `item.onSelect` with no catch, and `buildMemberItems`' action opens a DM over the network, so an `ApiException` escapes to the zone with the palette still open and nothing said.
`:178` renders the store error arm as `SizedBox.shrink()`, which reads as "no matches" rather than "the local store failed" - the exact distinction `channel_search.dart` and `message_transcript.dart` both go out of their way to preserve.

**Smaller correctness items.**

| What | Where | Why it matters |
|---|---|---|
| `SyncController.start()` documents itself safe to call repeatedly and has no in-flight guard | `providers/sync_controller.dart:83` | a sign-out during catch-up leaves an unauthenticated retry loop running for the rest of the launch, because the in-flight start reaches `_scheduleRetry` after `stop()` cancelled the timer |
| `FileKeyStore` caches the rejected open future | `packages/platform/.../persistent_key_store.dart:122` | one transient failure disables secret storage (session token, push key) for the process, with no recovery short of a restart; on desktop this is the only key store |
| A failed screen-source enumeration is indistinguishable from "no screens" | `packages/rtc/.../voice_session.dart:218` | a Wayland portal refusal returns `const []`, the caller returns early at `voice_call_controls.dart:103`, and the share button does nothing whatsoever; `_lastError` is set and never read |
| `ScreenShareView` resolves tracks only from remote participants | `packages/rtc/.../screen_share_view.dart:60` | latent, but `screenShareViewFor`'s doc states no remote-only contract, so a self-preview will render a permanent placeholder |
| `ApnsTokenChannel` drops the native registration-error reason on the async path | `packages/platform/.../apns_token_channel.dart:93` | reports a permanent failure as "no token yet" for that attempt and discards the one piece of native diagnosis that reaches Dart; self-heals on the next fetch |
| Three enums parse with `values.byName` | `models_presence.dart:40`, `client_presence.dart:31`, `models_moderation.dart:44` | throws untyped `ArgumentError` past every `on ApiException`; the tolerant `parse` discipline is documented in two other places and not these three |
| A 401 that survives the post-refresh replay does not clear the session | `client_transport.dart:49` | `isSignedIn` stays true, nothing emits on `changes`, and the user sits in a shell where every request 401s with no route to sign-in |
| 413 has no typed exception | `client_transport.dart:127` | the attachment and emoji routes layer `DefaultBodyLimit` at the same threshold as their own check, so 413 is what an oversized upload really returns, and callers cannot branch on "that file is too big" |
| Path segments are interpolated without encoding | `client_messages.dart:119`, `:130` | a reaction emoji containing `/` misroutes to a 404 indistinguishable from a deleted message; the same-file doc reasons about colons and stops there |
| The read marker is written from inside a `StreamBuilder` builder | `screens/channel_screen.dart:318` | a build-phase store write plus HTTP call against the table the enclosing builder watches; it does not loop only because of a guard whose recorded reason is now false |
| `_InviteDialog._verify` calls `setState` post-await unguarded on two paths and guards on two others | `screens/onboarding_screen.dart:221`, `:232` | the dialog is barrier-dismissible, so the window is real; the throw becomes an unhandled async error |
| `mounted` and `context.mounted` are used interchangeably around the same await | `screens/admin/invites_screen.dart:104` and 5 more | a redundant pair one line apart, in a codebase where `ref.invalidate`-after-dispose has already been hunted once |
| Store-open failures bind the error and discard it | `screens/channel_screen.dart:270`, `home_shell.dart:177`, `role_assign_sheet.dart:85` | the app ships a diagnostics log built for this, and `installDiagnostics` hooks only `FlutterError.onError` and `PlatformDispatcher.onError`, so a provider future's throw never reaches it |
| `Image.memory` has no `errorBuilder` | `widgets/attachment_view.dart:132` | bytes that pass the server's sniff but fail to decode paint nothing in release, where a "could not load" state sits a few lines above |
| Leaving a call resets the mic and deafen state to defaults | `providers/voice_controller.dart:202` | a mute never survives to the next join, and it repeats every call |

### 4. Design grammar and token drift

**24 raw `fontSize` literals bypass the six-step scale, and 13px is now a de-facto seventh step used nine times.**
The scale is 11/12/14/15/20/24 plus code at 13.5 (`app_typography.dart`).
13 appears at `onboarding_screen.dart:165`, `:274`, `:369`, `voice_call_controls.dart:210`, `voice_screen.dart:132`, `:158`, `:392`, `server_notice.dart:38` and `settings_section_header.dart:84`.
Nine further literals duplicate a step by hand rather than naming it, and three sites write raw `FontWeight.w600` where `AppWeights.semi` exists to record that decision once.
`widgets/settings_section_header.dart:73` is the header on every settings pane and renders at 16 and 13, between two defined steps, next to a sibling in the same file that uses the tokens correctly.
`packages/rtc/.../screen_share_view.dart:77` is the sharpest single case: a hardcoded `Color(0xFF9AA4AD)` at `fontSize: 13`, because `rtc` cannot depend on the design system, so the one string this package paints is a seventh grey invisible to the contrast gate.
Found by four passes.

**Six loading spinners render at Material's default 4px stroke where eight use the house 2px, and two settings sections use a progress bar.**
`async_view.dart:85` sets the house style; `home_shell.dart:176`, `channel_rail.dart:123`, `channel_screen.dart:269`, `overwrite_target_picker_sheets.dart:61` and `:93`, `role_assign_sheet.dart:84` take the default.
The three surfaces a user waits on most are the chunky ones.

**Account deletion is the only place danger is rendered as a filled button.**
`widgets/personal_account_sections.dart:234` styles a `FilledButton` with `dangerText` as its background; `confirm_dialog.dart:28` states the rule at the point of use, CLAUDE.md states it, and eight other callers follow it.
`cancelLabel`, the parameter added specifically so this caller could reuse the shared dialog, exists with a default and is passed by nobody.
Found by two passes.

**Two admin pickers render a member at Material's default type.**
`screens/admin/role_assign_sheet.dart:96` and `overwrite_target_picker_sheets.dart:104` are raw `ListTile`s with no design-system type at all, so the same person looks like a different kind of thing there than in the profile or the message list.
`widgets/pinned_messages_sheet.dart:140` is the only messaging row on a raw `ListTile`, and it renders `pin.message.content` as plain text, so a pinned message containing a fence, a mention or a shortcode shows raw backticks and colons where search results show it rendered.
`widgets/space_settings_section.dart:58` builds six navigation rows as raw `ListTile` in a file that imports the design system, so the largest cluster of navigation rows in the app is off-density from the rail beside it.
`screens/voice_screen.dart:249` (`_PreToggle`) re-implements a tappable row without the haptic, pressed state, focus ring or semantics `AppListRow` supplies.
The 28 raw `ListTile` and 10 raw `TextField` sites in `app/lib` are partly a library gap rather than laziness: `AppInput` has no label or helper slot, which is why sign-in and onboarding cannot use it.

**Smaller drift.**

| What | Where |
|---|---|
| Sheet titles split between `AppText.body` (3 sheets) and `AppText.heading` (3) | `create_channel_sheet.dart:95`, `poll_composer_sheet.dart:106`, `manage_channel_sheet.dart:163` vs `role_editor_sheet.dart:110`, `role_assign_sheet.dart:75`, `member_roles_sheet.dart:96` |
| Two unsourced disabled opacities, 0.4 and 0.45, with no opacity token to pick from | `design_system/.../core/button.dart:209`, `icon_button.dart:150` |
| Two raw 150ms durations and one `Curves.easeOut`, the only motion values not named in `AppMotion` | `forms/toggle.dart:77`, `segmented_control.dart:120` |
| `showAppSheet`'s compact branch silently drops `bare`, `maxWidth` and `scrolls` | `design_system/.../surfaces/sheet.dart:40`, so two callers get a menu border nested inside a sheet surface on a phone |
| Admin list separator gap drifted between the three screens that share the shape | `reports_screen.dart:41` (s12) vs `roles_screen.dart:49`, `removed_members_screen.dart:44` (s8) |
| Picker sheet height is a documented constant in one file and a bare `0.7` in its neighbour | `overwrite_target_picker_sheets.dart:26` vs `role_assign_sheet.dart:61` |
| The "scale then floor at 9" rule the speaking glyph says it shares with the presence dot is duplicated | `core/speaking_ring.dart:133` vs `avatar.dart:56` |
| The canvas cursor palette is load-bearing for the server-fingerprint colour strip | `app_tokens.dart:430`, consumed only by `widgets/server_fingerprint_step.dart:77`; Phase 6 will retune it without knowing |
| The join preview stacks two spacers, leaving the one 24px gap in a column of s16 | `screens/voice_screen.dart:147` |
| The report dialog is bare Material in the one surface that is a member's whole recourse | `widgets/report_dialog.dart:19` |

### 5. Docs that contradict their code

CLAUDE.md's own rule is that a stale note costs more than a missing one.
Two of these have already sent work at problems that do not exist: `channel_screen.dart`'s "no key" premise produced a "critical" finding in this audit pass that had to be refuted, and `_PinPill`'s comment forwards the reader to a knowledge-base entry that has itself been superseded.

| Claim | Where | Reality |
|---|---|---|
| `[ConversationPane]` builds this with no key, so the State is reused across channels | `screens/channel_screen.dart:61`, `:79` | `router.dart:144` has keyed each channel page since ca1669b, so the State is fresh per channel; the two workarounds it justifies are dead weight |
| Every tappable component routes through `AppHaptics` | `design_system/.../app_haptics.dart:5` | three do; `AppMenuItem`, `AppChip`, `AppToggle`, both segmented controls and `AppSlider` fire nothing, and `impact()` has no caller anywhere |
| Presence is five shapes: filled disc, hollow ring, dash, crescent | `app_tokens.dart:330` | the enum is filledDisc, triangle, notchedSquare, hollowRing, slashedRing; four colours for five states, and the same file's neighbour claims five colours |
| `probeAll` asks the portal how many screens and windows | `packages/rtc/.../media_capabilities.dart:104` | the implementation excludes windows because enumerating them segfaults the process on Wayland, and the warning lives only inside the one implementation |
| The family cache means an author is fetched once per session | `providers/user_profiles.dart:8` | it is `autoDispose.family` watched only from a transcript row, so scrolling past the cache extent refetches `GET /users/{id}`; this is the whole justification for not reusing the member list |
| Pinning a message has nowhere to live, since it needs a shared context menu this client does not build | `widgets/channel_header.dart:124` | `message_context_menu.dart:199` is that affordance, wired and gated per message |
| Providers are hand-written so the graph is readable in one file | `providers/providers.dart:4` | there are 21 provider files and this one is 349 lines |
| The class doc for `TypingController`, including why there is no local TTL | `providers/typing_controller.dart:17` | the whole run has slid onto a private `Duration` constant; the class carries no doc |
| Pass `(value:, isLoading:, error:)` through `AppAsyncState` | `design_system/.../async_view.dart:42` | the constructor is `({this.data, this.error})`; the class doc three lines above gives the correct snippet |
| Throws `NotImplementedException` on a deployment with no SFU | `packages/api/.../client_voice.dart:9` | that type exists nowhere in the repo; the real one is `NotConfiguredException`, named correctly eleven lines lower |
| One tag per file | `packages/api/.../client.dart:13` | `client.dart` carries six tags, and the `invites` tag is split across two files |
| Only `refreshOnce` dedupes, but the class doc promises it generally | `providers/channel_refresher.dart:2` | `refresh` sets nothing, and both are called |
| `signedInProvider` exists so routing can react | `providers/providers.dart:235` | routing watches `sessionProvider` and a `_SessionListenable`; the provider and its transformer have no consumer |
| Three doc comments cite `settings_screen.dart` | `appearance_settings_section.dart:4`, `confirm_dialog.dart:3`, `providers/admin_providers.dart:6` | the file does not exist; the confirm_dialog one sends the reader to the wrong file for the copied dialog |
| Widest a nav column gets | `widgets/settings_panes.dart:55` over `_twoPaneFloor = 800` | the nav column is a fixed 240; 800 is the two-pane switch, which the second sentence says correctly |
| Any of the four bits that gate a row | `widgets/space_settings_section.dart:20` | the body tests five |
| The library header, and a doc comment attached to nothing | `widgets/personal_status_sections.dart:2`, `:101` | the file defines two sections, not three, and ends in an orphaned `///` for a removed one |
| The frame every settings and administration screen sits in | `screens/settings_screen_scaffold.dart:2` | seven of nine; `personal_settings_screen.dart` uses `SettingsPanesScaffold` and `debug_log_screen.dart` builds a bare Scaffold |
| Personal settings folds in mic level, sensitivity, push-to-talk and share quality | `screens/personal_settings_screen.dart` header | there is no sensitivity control and no push-to-talk anywhere in the client, and `voice_settings_screen.dart` contains no screen |
| `AppInfoSection` keeps its own group header so it does not read as the tail of the account section above it | `widgets/app_info_section.dart:5` | `AccountSection` is now below it, inside a pane already titled "About slim-m", which also puts account deletion under About |
| Kept in the tree at full size while hidden, and the caller wraps this in a `Flexible` | `widgets/composer_extras.dart:237` | six lines below, the inline comment says the opposite and the `Visibility` passes no `maintainSize`; there is no `Flexible` at the call site |
| Enter saves, matching the composer's own field | `widgets/message_edit_field.dart:10` | the binding is unconditional where `ComposerField` deliberately switches on `usesSoftKeyboard`, so on a phone Enter inserts a newline, there is no Escape, and the hint advertises both anyway |
| Duplicated because the wire type differs from the local one | `widgets/pinned_messages_sheet.dart:25` | there are three copies of `_authorLabel`, two of them over the same wire type, and the comment reassures the reader that the third does not exist |
| The library doc of `models_version.dart` | `packages/api/.../models_version.dart:2` | dangling, with no `library;`, so the trust-on-first-use reference material does not render; four further doc references point at names not in scope |

### 6. Dead code and unused surface

| What | Where | Note |
|---|---|---|
| Two persisted voice preferences have no reader anywhere | `screens/voice_settings_screen.dart:85` | `screenShareQuality` is a second mechanism for a decision the share dialog already owns and re-asks on every share; the sounds toggle and its callout describe behaviour with no implementation and no audio dependency in the client at all |
| Seven public api methods with no caller and no test | `client_canvas.dart:15`, `client_admin.dart:12`, `:21`, `client_voice.dart:23`, `client_users.dart:16`, `:28` | admin password recovery is shipped-but-unreachable, the same shape as the `Routes.settings` gap PR #50 found; two whole extensions could vanish from `api.dart`'s show list and fail nothing |
| `signedInProvider` and its `_startWith` helper | `providers/providers.dart:235`, `:338` | three references, all internal |
| `AppSizes.iconStroke`, `icon32`, `AppSpacing.s40`/`s48`/`s64` | `design_system/.../app_metrics.dart:76` | `iconStroke` reads as the icon-weight enforcement point; the real mechanism is the `300` suffix in `app_icons.dart` |
| `AppHaptics.impact()` | `app_haptics.dart:34` | documented for call controls, which get nothing |
| `_FirstOrDefault` extension reinventing `firstOrNull` | `screens/voice_settings_screen.dart:81` | one call site |
| `_listEquals` reimplementing `listEquals`, already in scope | `packages/rtc/.../voice_session.dart:445` | nine lines in the package's largest file |
| `Routes.channelPattern`, a hand-written duplicate of a path the router composes by nesting | `routing/routes.dart:26` | read only by two tests, each building its own router |
| `NoChannelSelected`, a wrapper class whose whole body is another private widget | `screens/home_shell.dart:149` | one consumer, no test |
| `channel_screen.dart` re-exports `newMessageId`, and only a test depends on that route | `screens/channel_screen.dart:37` | reads as a deliberate public seam |
| `_emoji` passes `category` and `recent` to `pickerResults`, which cannot read them for a non-empty query | `widgets/composer_autocomplete_items.dart:81` | the argument says "only this Space's emoji" and the call returns unicode too |
| Nine settings and admin routes are the same three lines nine times | `routing/router.dart:83` | 45 lines carrying two facts each, and no place to hang a permission redirect |
| Vestigial local, duplicated guard clause, hardcoded tracking arithmetic | `member_pane.dart:230`, `space_settings_section.dart:97`, `onboarding_shell.dart:134` | each disagrees with a better version a few lines or one file away |

### 7. Accessibility

| What | Where |
|---|---|
| The microphone pre-toggle publishes no `button` or `toggled` semantics on the screen whose purpose is deciding whether the mic opens | `screens/voice_screen.dart:249`; `_ControlButton` in the in-call bar does wrap itself in `Semantics` |
| The fullscreen image viewer has no Escape binding while every other overlay in the package has one | `widgets/fullscreen_image_viewer.dart:113`; on desktop the only exit is tabbing to the close button |
| The poll option's semantic label reads "1 votes" where the summary two lines away pluralises | `widgets/poll_view.dart:85` vs `:51` |
| The blocked list renders raw uuids to a screen reader as well as to the eye | `widgets/personal_account_sections.dart:131` |

### 8. Tests and gates

**`flutter_lints` is a dev dependency of all seven client packages and no `analysis_options.yaml` activates it for six of them.**
The only file is `packages/app/analysis_options.yaml`; options resolve by nearest enclosing directory and there is none at `client/` or the repo root, so `dart analyze` applies zero lints to api, data, design_system, platform, rtc and voice_canvas.
Visible consequence in the audited code: `client.dart:71` writes `}) : baseUrl = baseUrl,` where `this.baseUrl` is meant.
This is also why `comment_references` and `dangling_library_doc_comments` cannot be on, and therefore why the four dangling doc references and the dangling library doc above survive.

**Multi-line `///` blocks in statement and argument position bypass the comment-cap gate.**
`scripts/check-comment-cap.sh` matches `^\s*//[^/!]` and exempts `///` by construction, justified by a doc comment's audience.
A `///` inside a function body, an argument list or above an `if` has no audience: it reaches no `dart doc` and no caller.
Sites found: `sync_controller.dart:126`, `:161`, `:189`, `channel_refresher.dart:38`, `providers.dart:110`, `:160`, `onboarding_screen.dart:217`, `:328` (seven lines), `channel_overwrites_screen.dart:197`, `emoji_picker_grid.dart:149`, `emoji_picker_panel.dart:124`.
So the register's numbers stop describing those files, and a comment too long for the cap can be relabelled rather than shortened or moved.
Found by three passes.

**The client's `Perm` mirror is required to match the server exactly and nothing gates it.**
`permissions.dart:4` says so; the 16 constants do match `crates/slimm-server/src/permissions.rs:35` bit for bit, and no test pins them.
A bit added server-side simply never appears in the role editor or the overwrites grid, because both iterate `Perm.editable`, and nothing says a bit is missing.
The repo already gates this class of drift where it matters, by parsing the source (`tests/openapi_contract.rs`, `tests/canvas_index.rs`).

**Coverage gaps that explain three of the confirmed defects.**

| Gap | Consequence |
|---|---|
| Every mount in `test/member_profile_test.dart` passes `onDone: () {}`, and nothing anywhere drives `showMemberProfile` through a real route | remove and report are broken in production and green in CI |
| No `watchChannel` test passes a `limit`; every assertion checks `rows.single` or `isEmpty` | the oldest-200 ordering has never been exercised |
| Nothing drives `MessageTranscript` at all | the missing item keys, and the lost edit text they cause, are unobservable |
| `EventConnection.connect` is exercised only by `live_server_test.dart`, which returns immediately without `SLIMM_TEST_SERVER`, and CI never sets it | the protocol-mismatch, ErrorEvent, no-hello and ready-timeout branches are uncovered; the ready timeout at `events.dart:199` leaks the socket, unlike the second timeout twenty lines below |
| `compression_interop_test.dart` rebuilds the socket URL by hand instead of calling `SlimmApi.webSocketUrl` | it would not catch a `webSocketUrl` regression, and it never runs anyway |
| `_base` and `_tokens()` are duplicated across four api test files | fixtures with no shared home |

### 9. File-size register

Measured on this branch, `.g.dart` and `.freezed.dart` excluded.
`scripts/check-file-budget.sh` warns at 300 and fails above 500; `scripts/file-budget-allow.txt` is a ratchet register of files already past 500 and treats each listed number as that file's ceiling.

**Library code over the 300-line review budget (none over 500):**

| Lines | File | Named seam |
|---|---|---|
| 500 | `app/lib/src/features/voice/screens/voice_screen.dart` | `_JoinPreview` + `_WhoIsHere` + `_PreToggle` (83-293): the pre-call screen, no dependency on in-call state, leaving `_InCall`/`_ParticipantRow`/`_openProfile` at about 200. **At exactly 500, so the next net line added fails the hygiene workflow.** It has been split for this reason once already (`voice_call_controls.dart` says so in its header) and has grown back |
| 481 | `rtc/lib/src/voice_session.dart` | the screen-share members (`screenShareNeedsSource`, `screenShareSources`, `setScreenShareEnabled`, `captureOptionsFor`, `_isSharing`, `screenShareViewFor`) as a collaborator over the room, the way `local_audio.dart` took the audio triple. Both siblings record being split out at the 500 ceiling, so the pattern has been reactive twice |
| 461 | `app/lib/src/providers/push_controller.dart` | the lifecycle-reporting half (`_stateLabel`, `didChangeAppLifecycleState`, the foreground heartbeat, `_reportLifecycle`, 361-446), which shares nothing with registration but a status predicate. At 92% of the hard ceiling |
| 446 | `design_system/lib/src/app_tokens.dart` | none, deliberately: a flat value catalogue with no seam |
| 412 | `app/lib/src/features/composer/widgets/composer.dart` | none named; the duplicated action list (below) comes out of it |
| 409 | `app/lib/src/features/members/widgets/member_profile.dart` | none named |
| 396 | `app/lib/src/features/auth/screens/onboarding_screen.dart` | none named; the three duplicated address validators are in it |
| 388 | `app/lib/src/features/auth/screens/sign_in_screen.dart` | none named |
| 385 | `app/lib/src/features/members/widgets/member_profile_sections.dart` | none named |
| 374 | `app/lib/src/features/channels/screens/channel_screen.dart` | three: the read marker (`_markedReadSeq`, `_markReadUpToLatest`, `_markRead`, about 55 lines); permission gating and action wiring (`_actionsFor` 148-176 plus the five handlers 127-144), which `channel_message_actions.dart` already owns as a concern; and `_hydrateExtras` (84-94), which belongs to the extras controller. It has shed two pieces already without getting under budget |
| 362 | `app/lib/src/features/voice/providers/voice_controller.dart` | `VoiceState` plus `copyWith` (19-99), 80 lines with no behaviour, into `voice_state.dart` |
| 357 | `app/lib/src/features/auth/widgets/onboarding_shell.dart` | none named |
| 353 | `app/lib/src/features/voice/screens/voice_settings_screen.dart` | contains no screen; rename to `voice_settings_body.dart` |
| 349 | `app/lib/src/providers/providers.dart` | `AppThemeChoice` + `ThemeController` + `themeChoiceKey` (269-318), a self-contained 50 lines |
| 338 | `api/lib/src/models.dart` | three, along seams the file already draws with section comments: `models_session` (TokenPair, Ticket), `models_voice` (VoiceToken, VoiceRosterParticipant), `models_sync` (ReadState, ScopeCursor, ScopeDelta). Nine siblings already carry a "split out of models.dart purely to stay under this repo's line budget" header, so this is the file whose own header explains the splitting |
| 334 | `design_system/lib/src/components/surfaces/list_row.dart` | the two animated marks (unread dot, selection marker) as private widgets. Also the highest comment-cap debt in the design system at 11 runs, where the next highest is 4, so splitting moves several of those onto exempt doc comments |
| 322 | `app/lib/src/features/settings/screens/admin/invites_screen.dart` | none named |
| 309 | `app/lib/src/features/channels/widgets/channel_rail_frame.dart` | none named |
| 303 | `app/lib/src/widgets/composer_extras.dart` | none named |

**Test files, all registered:** `push_controller_test.dart` 925, `new_routes_test.dart` 665 (split along the groups it already has; it is named after a pull request rather than anything it covers), `session_persistence_test.dart` 588, `message_row_test.dart` 509.
A further 19 test files sit between 300 and 500 unregistered, which is within the gate.

**Comment-cap register:** 154 of the 263 listed files are under `client/`, carrying 392 grandfathered runs.
The api package is 14 of those files and every one of its runs is exactly two lines, so the whole package's entries retire together in one pass with no reasoning lost - the cheapest slice of that register to close.

**Two stale notes in CLAUDE.md's own file-size list:** it names `sync_controller.dart`, `member_pane.dart` and `channel_screen.dart` at 316, 396 and 583; they measure 285, 255 and 374.

### 10. Remaining duplication worth naming

| What | Where | Shape of the cost |
|---|---|---|
| Report and block implemented twice, once per subject kind, with byte-identical success copy | `widgets/member_actions.dart:19`, `:50` and `channel_message_actions.dart:155`, `:181` | two copies of the safety flows most likely to need a copy or behaviour change, each with its own catch |
| The composer's action set defined twice, once per input density | `widgets/composer_extras.dart:195` (sheet) and `widgets/composer.dart:344` (icon row) | a new action is two edits, and a label can drift between what a phone sees and what a desktop sees |
| The session-edge listener written out twice, comment included | `providers/sync_controller.dart:37` and `push_controller.dart:112` | the app's core session rule (only the 0-to-1 and 1-to-0 edges matter, subscribe before reading) stated twice, already drifted cosmetically |
| `channel_overwrites_screen` repeats its picker row, its submit tail and its pick-a-target body within one file | `screens/admin/channel_overwrites_screen.dart:194` and `:227` | the three-line rationale for the transparent Material survives on only one copy, in the screen that can replace every permission for a role in one write |
| The `TextField` chrome opt-out block duplicated verbatim, comment included | `composer_extras.dart:114` and `message_edit_field.dart:81` | a design-system statement written per widget; a third borderless field copies it a third time |
| `AttachmentView` re-inlines `AttachmentPlaceholder`'s box for its error state | `widgets/attachment_view.dart:96` | 420 and 168 are now magic numbers in two files and the loading and error placeholders will drift |
| `ScreenShareQuality` has two label functions with different strings for the same value | `voice_call_controls.dart:235` vs `voice_settings_screen.dart:296` | settings says "Smooth", the share dialog says "Smooth, for anything moving" |
| The retry-or-forbidden failure block duplicated on raw Material widgets | `channel_search.dart:84` and `pinned_messages_sheet.dart:95` | both bypass `AppButton` and `AppText`, so a change to how a 403 reads is two edits |
| `probeAll`'s results cross a package seam as a string-keyed map dereferenced with `!` | `widgets/media_capability_section.dart:116` over `rtc/.../media_capabilities.dart:89` | keys duplicated as literals on both sides of a package boundary with nothing checking they agree; a third probe means hand-editing the widget |
| `ChannelRefresher` fans out one unbounded read-state request per channel on every connect and reconnect | `providers/channel_refresher.dart:41` | thirty channels means thirty simultaneous requests before the list is usable, repeated on every socket drop, for state that changes far more slowly than the connection |
| Nothing narrows a `voiceControllerProvider` watch | `channel_rail.dart:65`, `channel_rail_frame.dart:227`, `home_shell.dart:105` | `VoiceState` has no value equality and carries `isSpeaking`, so the whole rail and the shell footer rebuild several times a second during a call for two scalars |
| The member pane re-derives and re-sorts the whole roster per presence event, with `toLowerCase` inside the comparator | `member_pane.dart:100`, `member_presence.dart:126` | one person going online re-partitions 200 members and runs two allocating sorts |
| `message_text` re-splits fences, re-lexes code and re-tokenizes inline runs on every build, and the lexer allocates a substring per character | `widgets/message_text.dart:146`, `message_code_lexer.dart:62` | `line.startsWith(needle, at)` does the same job with no allocation; content is immutable once stored |
| The emoji picker rescans the whole catalog inside build, including on an arrow-key `setState` | `widgets/emoji_picker_panel.dart:131` | per keystroke the scan is the feature; per arrow key it is waste |
| `VoiceSession` reapplies local audio state over every remote track on every room event | `rtc/.../voice_session.dart:410` | deliberate by design (`local_audio.dart`'s doc explains the reapply-on-resubscribe guarantee), but it is one method-channel message per track per event, and an awaited volume round trip per track on mobile |
| `_SessionListenable` stores its subscription as `dynamic`, and neither it nor the router is ever disposed | `routing/router.dart:171` | `.cancel()` is a runtime lookup in the path that keeps routing reacting to revocation, and containers leak per test |
| An over-long channel name silently disables Save with no counter and no message, and the create sheet does not check at all | `manage_channel_sheet.dart:61`, `create_channel_sheet.dart:53` | the topic field a few pixels below already solved this; the two sheets disagree about one server rule (64 chars, `channels.rs:259`) |
| The 100-id batch cap on `/users` and `/presence` is neither documented nor enforced client-side, and the guard is `>=` so the real ceiling is 99 | `client_users.dart:25`, `client_presence.dart:7` | latent (the member fetch defaults to 50), and when it goes live `presence_controller.dart:43` swallows the error by design, so the symptom is a silently empty presence map |
| `listUsers` guards an empty id list and `listPresence` does not, and neither short-circuits the round trip | `client_users.dart:31` vs `client_presence.dart:14` | two spellings of one decision in adjacent batch endpoints |
| The same decode idiom at roughly 40 call sites because `_send` returns `Object?` | `client_users.dart:32` and 39 more | the cast is where a wire-shape mismatch surfaces as a raw `TypeError`, escaping every `on ApiException`; note `schema_coverage_test.dart:206` parses for the literal-led `_send('METHOD', 'path'` shape, so any helper must keep it |

### Three things I would do first

**1. The message path: `message_store.dart`'s two ordering bugs plus item keys on the transcript.**
`watchChannel`'s ascending limit, the pending row's `seq` of 0, and the missing `ValueKey(message.id)` are three small edits in two files, and together they are the only findings in this area with no in-app recovery.
The ordering one silently disables the transcript and the read marker for any channel that reaches 200 messages, which is one evening of use, and there is no test in `packages/data` that would notice.
The keys one loses text the user has typed, which the project treats elsewhere as a line it does not cross.

**2. `member_profile.dart`'s dismiss-then-act helper.**
Removing a member and reporting a member are the two moderation paths with a single call site each, both currently guaranteed to throw `StateError` past every catch, and both green in CI because every test passes `onDone: () {}`.
The fix is to resolve what the action needs before the surface is dismissed, and the test that would have caught it is one case driving `showMemberProfile` through a real route.
This is a safety-model gap, not a polish item.

**3. The failure-reporting migration onto `runGuarded` and `AppErrorState`.**
It is the largest single componentisation win in the client (24 write sites, 26 SnackBars across 16 files, five reinventions of the inline error), it is what the cleanup question was asking for, and it closes a defect the repository already has a committed test against: `client_transport.dart` wraps every network fault in a string containing the method, path and Dart exception, and 24 sites render it.
Do `voice_controller.dart:196` first inside that work, because its string reaches a full-screen surface on the flagship feature.
Two prerequisites are cheap and belong in the same pass: add the missing `ForbiddenException` clause so the 401 and 403 wording stops being inverted, and put an `analysis_options.yaml` at `client/` so the six unlinted packages start being analysed at all.

One scheduling note rather than a fourth item: `voice_screen.dart` sits at exactly 500 lines, so the next net addition to voice fails the hygiene workflow for a reason unrelated to the change making it.
Its seam is already named (the pre-call screen, lines 83-293), and splitting it before it is next touched is cheaper than discovering it under CI pressure.

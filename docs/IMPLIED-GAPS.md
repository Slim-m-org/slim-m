# Implied gaps

Things the product now needs because of what was recently built in the last two days, which nobody planned for.
The features in scope: threads, replies, calling in a DM, markdown, the actionable report queue, drag-to-reorder channels, image paste, message jump-to.

Each entry is grounded in the current code, cited by file.
Ordered by what would hurt first, not by feature.
Checked against `docs/BACKLOG.md`'s out-of-scope section and the decision records first, so nothing here is something already decided against.

## 1. A thread reply pushes everyone who can view the parent channel, not the thread's participants

**Fixed 2026-08-04.** `push::message_recipients` now narrows a thread's push audience to the thread's own participants - the parent message's author plus everyone who has posted into it - derived from existing rows with no new table, and always intersected with the already-permission-checked viewer set so the narrowing can only remove a bystander, never grant a view.
Mentions cut through, and turned out not to exist server-side at all before this: `@name` was purely client rendering.
See PR #357 and `crates/slimm-server/tests/thread_push_narrowing.rs`.
Still not built, and named rather than missing: an explicit follow concept, so somebody who only read a thread and was never mentioned gets nothing.
The rest of this entry is kept for the record of what the gap was.

**What is missing.** Threads were built by reusing the ordinary channel machinery wholesale, which is the whole point of the design (`crates/slimm-server/src/store/threads.rs`'s own module doc: "every other feature ... keeps working unchanged").
Push fan-out is one of those reused things, and reuse here is the bug.
`push::message_recipients` (`crates/slimm-server/src/push/recipients.rs`) computes who gets woken with `store.viewers_among(channel_id, &candidates)`, and `viewers_among` resolves a thread's permissions to its parent's through `Store::permission_channel` (`crates/slimm-server/src/store/permissions.rs`) exactly the way every other permission check does.
So the viewer set for a thread's own channel id is, by construction, the same set as the parent channel's: everyone with `VIEW_CHANNEL` there and a registered push device, filtered only by whether their device is currently foregrounded (`is_foreground_and_recent`, `crates/slimm-server/src/push.rs`) and a per-`(channel, recipient)` debounce that collapses a burst to one wake.
None of that is thread-aware. A reply to a two-person side conversation inside a fifty-member channel pushes all fifty backgrounded members, once per debounce window, for every reply.

**Why it matters.** The owner named the model he wanted directly, quoted in `docs/decisions/0005-threads.md`: "we click reply in thread, it opens up a hidden sub channel and we communicate there, I like how slack does it."
Slack's actual behaviour is that only thread participants (plus anyone who reacted or was mentioned) get notified of a reply by default - the whole point of a thread, in the model the owner asked for, is that it does *not* broadcast to the channel.
The current build inherits the opposite behaviour by construction, silently, because nothing about the reused push path knows a thread is different from a channel.

**Urgent or latent.** Urgent once threads see any real use with more than two or three people in the parent channel. It costs nothing to trigger - open a thread, reply a few times - and the failure is not a crash or a permission leak, it is every backgrounded member's phone buzzing for a conversation they may have no interest in, repeatedly.

**Rough cost.** This is the "looked small and was not" shape. `message_recipients` would need to know whether `channel_id` is a thread's own channel and, if so, narrow candidates to thread participants (authors of messages already in it, or a separate follow list) rather than the parent's whole viewership - which is new state, not a filter over existing state. It touches push, and needs a decision about the fallback (nobody has replied yet, or the parent's own author) that has no existing structure to reuse the way `permission_channel` did for permissions.

## 2. A DM call has no ring, no push, and no passive signal anywhere the callee is not already looking

**Half fixed 2026-08-04.** The in-app half is built: `Event::VoiceActivityChanged` carries a channel id and nothing else (naming a joiner would hand every viewer what `GET .../voice/roster` deliberately refuses them for a hidden participant), published on a first heartbeat, a real hangup, and a stale sweep, gated on the ordinary channel-scoped view check.
A DM row now shows a call in progress and opens straight into it.
See PR #358 and `crates/slimm-server/tests/live_voice_events.rs`.
**The ring half is still open** and is issue #212's CallKit/VoIP bridge: nothing wakes a backgrounded or closed app, so this only reaches somebody who already has it open.
The rest of this entry is kept for the record of what the gap was.

**The in-app half is fixed.** `Event::VoiceActivityChanged` (`crates/slimm-server/src/hub/event.rs`) carries only a channel id, published from three sites - `http/voice.rs`'s `heartbeat` (a first heartbeat for a `(user, channel)` pair, never a repeat) and `forget_heartbeat` (a real forget only), and `lib.rs`'s stale-heartbeat sweep - each read-before-write against `VoiceService::has_heartbeat` so a routine refresh never republishes. Gated through the ordinary channel-scoped `VIEW_CHANNEL` check in `http::ws::authorize`, the same one every other channel event uses, which for a DM resolves to exactly its two participants. `voiceRosterProvider` (`client/packages/app/lib/src/providers/voice_roster.dart`) now nudges its poll on that event instead of only its 15-second timer, and `DmRow` (`client/packages/app/lib/src/widgets/dm_row.dart`) watches it to show a call-in-progress icon, tapping which opens straight into the call pane. See `crates/slimm-server/tests/live_voice_events.rs` and `crates/slimm-server/tests/voice_sweep.rs`'s `a_swept_stale_heartbeat_publishes_voice_activity_changed`. The real ring - waking a backgrounded or closed app - is still issue #212, deliberately not built here.

**What was missing.** PR #306's own description says it: "Ringing is out of scope: nothing server-side pushes a wake for a call."
That is honestly stated as a known limitation of what shipped, but tracing it further than the PR body did finds there is *no* signal of any kind, not just no push.
`crates/slimm-server/src/hub/event.rs` has no voice-related event at all - joining or leaving a LiveKit room publishes nothing over the WebSocket.
Client-side, a DM row in the rail is a plain `AppListRow` (`DirectMessagesSection`, `client/packages/app/lib/src/widgets/channel_rail_sections.dart`) using ordinary message-unread state (`channel.cursor > channel.lastReadSeq`); it does not watch `voiceRosterProvider` at all, unlike `VoiceChannelRow` for a real voice channel.
`voiceRosterProvider` itself only polls "while a rail row for that channel is actually on screen" (per the per-channel voice roster section of `CLAUDE.md`), and no DM row ever mounts one.
So a person who calls a DM contact has no way to reach them unless that contact happens to already have the DM's call pane open.

**Why it matters.** This is the feature working exactly as documented and still not doing the thing "calling" implies. A caller who hits Call gets silence with no indication whether the other side even knows.

**Urgent or latent.** Urgent in the sense that it is not a corner case - it is the first thing anyone will notice trying to use the feature for real, the first time the other person is not already staring at that DM.

**Rough cost.** Genuinely two different problems bundled under one name. A live, in-app signal (someone joined a DM voice channel while you're online) is a small, bounded piece: a hub event plus a rail-row listener, similar in shape to the thread `ThreadUpdated` event already built. A real ring - waking someone whose app is backgrounded or closed - is the CallKit/VoIP-push bridge already filed as issue #212 and explicitly deferred there ("it needs a Dart-to-native call lifecycle bridge that does not exist yet"), which is a separate, larger project. The in-app half is worth doing regardless of when the ring half lands.

## 3. The report queue does not enforce per-channel moderator exclusion for a message inside a thread

**Fixed 2026-08-02.** `channel_scopes_moderation` now resolves a thread to its parent through `Store::permission_channel` before deciding scoping, and `hidden_channels` was taught about the report-referenced channel ids `list_channels` never carries.
See the pre-trim `CLAUDE.md`'s "Moderation reaching only the channel kind it was written for" and `crates/slimm-server/tests/report_thread_scoping.rs`.
The rest of this entry is kept for the record of what the gap was.

**What is missing.** `channel_scopes_moderation` (`crates/slimm-server/src/store/channels.rs`) returns `false` for a thread's own channel, the same as it does for a DM:

```rust
channel.kind != super::dms::DM_CHANNEL_KIND && channel.parent_message_id.is_none()
```

For a DM that is correct - a DM has no per-channel overwrites for a moderator to be excluded by, so `report_visible_in` (`crates/slimm-server/src/http/reports.rs`) is right to fall back to the deployment-wide `MANAGE_MESSAGES` bit alone.
For a thread it is not correct: a thread's permissions are *not* opaque the way a DM's are, they resolve live to the parent channel's overwrites via `Store::permission_channel` - the same mechanism `channel_scopes_moderation` itself declines to use here.
The batched form, `hidden_channels`, has the identical gap: it is built from `store.list_channels()`, which excludes threads by design (`parent_message_id IS NULL`, per the threads work), so a thread's channel id is never in the set either side of the `moderatable` comparison and is therefore never excluded for anyone.

**Concretely:** an admin sets a per-channel overwrite denying a specific moderator `MANAGE_MESSAGES` (and typically `VIEW_CHANNEL`) on some channel - a private or sensitive channel, say. That moderator still holds `MANAGE_MESSAGES` at the deployment level for everything else. A message gets reported inside a thread hanging off a message in that excluded channel. The excluded moderator sees the report in their queue anyway, including the reported content snapshot (`ReportDto.snapshot`), because the report's channel id is a thread that both `hidden_channels` and `report_visible_in` treat as unscoped.

**Why it matters.** This is exactly the class of bug the project has already found and fixed once in this same file (see the pre-trim `CLAUDE.md`'s "Read bounds" section: "a moderator denied MANAGE_MESSAGES in one channel could not read its reports but could still dismiss them"). Threads reopened the same shape by being modelled on the DM branch instead of the general one.

**Urgent or latent.** Latent until a deployment actually uses per-channel overwrites to exclude a specific moderator from a specific channel *and* that channel grows a thread with a report in it. Real once it happens: the content snapshot is a genuine visibility leak, not just an inconsistency.

**Rough cost.** Small and localized. `channel_scopes_moderation` and `hidden_channels` need to resolve a thread to its parent (reusing `permission_channel`, or `thread_parent` which already exists) before deciding scoping, the same substitution `evaluate_channel_permissions` already makes. One function, one query added to the batch path, a test shaped like the existing `channels_where` equivalence tests.

## 4. Threads give a free way to multiply two hand-set moderation ceilings

**What is missing.** `MAX_PINS_PER_CHANNEL` (200, `crates/slimm-server/src/store/pins.rs`) and `MAX_OBJECTS_PER_CHANNEL` (20,000, `crates/slimm-server/src/store/canvas.rs`) are both keyed on `channel_id`. `Store::open_thread` (`crates/slimm-server/src/store/threads.rs`) creates a new channel row on demand, gated on nothing more than `VIEW_CHANNEL` plus `SEND_MESSAGES` in the parent (`crates/slimm-server/src/http/threads.rs`) - no ceiling on how many threads one channel may have. Each new thread channel gets its own fresh 200-pin budget and its own fresh 20,000-object canvas budget. The canvas pane is fully reachable inside a thread: `ThreadScreen` reuses `ChannelScreen` wholesale (`client/packages/app/lib/src/screens/thread_screen.dart`), which builds the same header carrying `CanvasOpenButton` that any other channel gets.

**Why it matters.** The canvas ceiling exists specifically because the canvas has no removal path at all - "an unbounded write here would be permanent" (the canvas section of `CLAUDE.md`). That reasoning assumed one canvas per channel was the unit being bounded. A channel can now spawn an unbounded number of threads, each carrying its own full-size canvas and pin board, for the cost of one `SEND_MESSAGES`-gated POST per thread. The ceilings still bound any single canvas or pin set; they no longer bound what a channel, or a deployment, can accumulate.

**Urgent or latent.** Latent - it takes deliberate or careless volume to matter, and nothing here is a security hole, just a ceiling quietly becoming much less of one. Worth having an opinion on before it is noticed the hard way.

**Rough cost.** A cap on live (non-deleted) threads per parent channel would be a small, contained change to `open_thread` - one more count-and-refuse in the same transaction the row insert already runs in, the same shape `MAX_PINS_PER_CHANNEL`'s own check uses. Whether that is even the right fix (versus, say, accepting per-thread budgets as intentional headroom) is a product call, not just an engineering one.

## 5. Reply and thread are two competing ways to answer one message, with zero cross-awareness

**What is missing.** The message context menu offers both `Reply` (an inline `reply_to_id`, rendered in the main transcript with a compact quote) and `Reply in thread` (`client/packages/app/lib/src/widgets/message_context_menu.dart`, both actions gated similarly and shown on the same message). `docs/decisions/0005-threads.md` originally treated these as alternatives to choose between - "A reply is a column on a message... A thread... is not a bigger version of a reply" - and then both shipped, live, as parallel affordances on every eligible message rather than one being chosen over the other.
Neither knows about the other: a thread's reply count (`ThreadReplySummary`, driven by `Store::thread_summaries_for_messages`) counts only messages inside the thread's own channel, nothing about inline replies pointed at the same parent; an inline reply's quote gives no hint that a thread also exists on the same message.

**Why it matters.** A conversation about one message can now fork across two independently-rendered response mechanisms with no link between them - someone reading the inline replies has no way to know a thread also exists, and vice versa. This is a product-shape question more than a bug: the owner asked for threads specifically as the "reply tightly" mechanism, and the plain `Reply` action is still sitting right next to it doing a version of the same job in the open.

**Urgent or latent.** Latent - both work correctly in isolation, and this is a discoverability/mental-model problem rather than a data or permission one.

**Rough cost.** Cheap either way once decided: hide `Reply` on a message that already has a live thread, or the reverse, or leave both and add a small affordance ("N replies" or a quote) cross-referencing the other. Client-only, no schema change.

## 6. Nothing lists a channel's threads, and a thread cannot be locked, made read-only, or kept private

The owner's own example, confirmed still true rather than something to rediscover. `crates/slimm-server/src/http/threads.rs` carries exactly one route - open (or reuse) the thread hanging off a message. There is no `GET` enumerating a channel's threads; the only way to find one is from the message it hangs off, via the batch-loaded `thread_channel_id`/`reply_count` on that message.
A thread's `VIEW_CHANNEL`/`SEND_MESSAGES` are always the parent's, resolved live through `Store::permission_channel`, "not a copy and not a synthesized overwrite" (`CLAUDE.md`'s threads section) - there is no way to narrow a thread's membership below the parent channel's, no lock, and no thread-specific moderation action beyond the generic `DELETE /channels/{id}` that removes it outright.
`docs/decisions/0005-threads.md` names both as explicitly undecided rather than accidentally missing ("Not decided here: whether a thread's VIEW_CHANNEL/SEND_MESSAGES inherit the parent's overwrites or carry their own, whether a thread needs its own entry point beyond 'reply in thread'").

**Urgent or latent.** Latent - both are real absences but neither is a correctness or safety problem, and both were named as open questions at build time rather than found now.

**Rough cost.** A thread-listing endpoint is a small, self-contained addition (one query, batched the way `thread_summaries_for_messages` already is). A private or lockable thread is a bigger question: it would need a thread to carry its own overwrite bucket instead of resolving purely to the parent, which is the "second authority" shape this project has repeatedly avoided elsewhere and would need to be justified the same way.

## 7. A thread carries no per-viewer unread signal anywhere outside the thread itself

**What is missing.** `ThreadReplySummary` (`client/packages/app/lib/src/widgets/message_row_parts.dart`) renders a reply count and a last-reply timestamp - global facts, the same for every viewer - and nothing about whether *this* viewer has seen the replies. Threads are excluded from `Store::list_channels` by design, so they never appear in the rail at all, and so never participate in the rail's unread-dot computation (`channel.cursor > channel.lastReadSeq`) the way an ordinary channel or DM does. `ChannelScreen` is reused wholesale for a thread, so read state (`lastReadSeq`) is tracked per thread channel server-side exactly like any channel - the data exists - but nothing client-side ever surfaces it next to the "N replies" affordance or anywhere else.

**Why it matters.** The owner's own hypothesis ("unread counts and notifications treat a thread as a channel") turns out to be backwards in practice: threads are *invisible* to the rail's unread system rather than mistakenly treated as a channel within it, and the one place a thread is surfaced at all (the reply-count line under a message) carries no unread/read distinction. A reader has to open every thread to find out whether there is anything new in it.

**Urgent or latent.** Latent - nothing is wrong, the affordance simply does less than it could. This gets more noticeable as thread volume grows.

**Rough cost.** Client-mostly: `ThreadReplySummary` would need to compare `lastReplyAt` against a locally-known "last seen" marker for that thread channel, which already exists as `lastReadSeq` once the thread channel row is in the local store - this is closer to "wire an existing signal through" than new machinery.

## 8. Two smaller, lower-confidence items worth a look

**Jump-to gives up after roughly 500 messages of backward paging, even when the target message genuinely exists further back.** `MessageJumpController._maxPages` is 10 pages of 50 (`client/packages/app/lib/src/providers/message_jump.dart`), a deliberate, documented bound ("enough for anything a search or a pin can name without one tap being able to fetch a channel's entire history"), not an oversight, and it fails honestly (`MessageJumpUnreachable`) rather than silently. Worth naming here only because two of this pass's new features lean on it for the first time in ways that can plausibly hit the bound: the report queue's "Jump to message" quick action, and a reply's compact-quote tap-through, both of which can now point at an old message in a channel that has kept moving. Latent, and arguably an acceptable trade rather than a gap - flagged for awareness, not for a fix.

**Selecting and copying message text on desktop has not been checked against markdown's inline `WidgetSpan`s.** `TranscriptSelection` (`client/packages/app/lib/src/widgets/transcript_selection.dart`) wraps the transcript in a plain `SelectionArea`, added before markdown's mention chips, inline-code spans and spoiler widgets existed as `WidgetSpan`s inside the rendered text (`message_text.dart`). Flutter's default handling of a `WidgetSpan` under selection does not guarantee the visible content round-trips through copy unless the span opts into selection explicitly, and neither `transcript_selection_test.dart` nor any other test exercises selecting across one of these spans. This is not a confirmed bug - it has not been run and observed - but the two features shipped independently and the interaction between them is untested in either direction.

## 9. Channel categories carry no permissions, and the owner confirmed that is fine

**Superseded 2026-10-13 by `docs/decisions/0064-category-permissions.md`.** The owner asked for category permissions; a category now holds overwrites that its synced channels copy. The rest of this section is history.

**What is missing, and why this entry differs from the rest of this document.** Every other entry here is something nobody planned for.
This one is the opposite: `docs/decisions/0006-channel-categories.md` names the gap explicitly before any code was written, and the owner confirmed it directly ("no permissions for categories is fine") rather than it surfacing as an accidental omission.
It is recorded here anyway, per that decision record's own instruction, because Discord's category model *does* let a category carry overwrites its channels inherit, and a contributor arriving from that expectation could otherwise assume this codebase's categories work the same way and go looking for the inheritance logic that was deliberately never built.

**What is actually true.** `channel_categories` (migration `0031_channel_categories.sql`) carries no `channel_overwrites`-style bucket, no allow/deny bits, nothing.
`Store::permission_channel` (`crates/slimm-server/src/store/permissions.rs`), the one place a thread's permissions resolve to its parent's, was never taught about `channels.category_id` and never will be under this decision: a category groups and orders, and grants or denies nothing.
Moving a channel between categories in `Store::reorder_channels` cannot change who can view, send in, or moderate it, because nothing reads `category_id` anywhere in the permission evaluator.

**Why it was declined rather than deferred.** Category-level overwrites would be a second permission resolution dimension layered on top of the one-hop thread resolution `permission_channel` already does, and this project has already shipped two silent read leaks from exactly that shape going stale against a channel kind or resolution path it was not told about (`evict_from_voice` missing DM calls, `channel_scopes_moderation` missing threads - see PR #336 ("Moderation reaching only the channel kind it was written for")). A wrong category-inheritance rule fails silently, as an over-broad or over-narrow view nobody notices, rather than loudly.

**Urgent or latent.** Not a gap to close, a decision to keep visible. Latent by design: nothing here needs fixing unless a future request specifically asks for per-category permissions, at which point this entry is the place to start, not a fresh investigation.

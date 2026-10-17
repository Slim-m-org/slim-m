# 0009 - The reconciliation debt reactions, pins and polls do not have, and would not need if they ever gained one

Date: 2026-08-05.
Status: designed, not built.
Nothing in this record is a plan to build a table.

`CLAUDE.md`'s "Reconciling an edit nobody was online for" section closed the project's oldest correctness debt for messages, and named one thing still open: reactions, pins and polls never reconcile after an offline gap.
It also said the day somebody adds a local table for one of the three, the debt reopens with none of `message_ops`' machinery reusable.
This record does two things: re-verifies that the precondition (nothing persists any of the three yet) still holds, and writes down the designed answer for the day it does not, rather than leaving that day to rediscover the problem from scratch.

## The precondition, re-verified against the real code, 2026-08-05

`client/packages/data/lib/src/database.dart`'s `@DriftDatabase` annotation lists exactly three tables: `Channels`, `Messages`, `ChannelCategories`.
The third one is new since the debt note was last written, and it does not reopen anything: `client/packages/data/test/local_schema_reconciliation_test.dart` already names it and explains why in its own doc comment - a category is replaced wholesale on every channel refresh, the same shape `channels` itself already has, never reconciled incrementally the way a reaction, pin or poll vote would need to be.
Nothing else has been added to that annotation.

`MessageExtrasController` (`client/packages/app/lib/src/features/messages/providers/message_extras.dart`) still holds reactions, attachments, polls and thread reply summaries in a plain Riverpod `Map`, rebuilt from whichever REST fetch most recently returned a message, and cleared only on sign-out.
`PinsController` (`client/packages/app/lib/src/features/channels/providers/pins_controller.dart`) is still `StateNotifierProvider.autoDispose.family`, refetching a channel's whole pin list on construction and on every live `MessagePinned`/`MessageUnpinned` event.
`PollView` and the composer both read a message's `poll` field straight off `MessageExtras`; there is no separate poll controller and no separate local storage for a vote.

Checked beyond the three named surfaces, since the note asked whether anything else added since has started caching server state the same way: `CallActivityTracker` (`providers/call_recap.dart`) says in its own doc comment that it "does not outlive the process," and is discarded per call; `CanvasActivityLog` (`screens/canvas/canvas_activity_log.dart`) is a plain `ChangeNotifier` fed by the canvas pane's own session and torn down with it; `notificationPreferenceProvider` and `spaceAnalyticsProvider` are both `FutureProvider.autoDispose`, fetched fresh on every watch; the notification-sound and display-preference controllers persist to `SharedPreferences`, but every key they write is a local device choice with no server truth to drift from, the same shape `notification_sound_settings.dart`'s own doc comment claims for itself.
None of these behave like a cache of mutable server state that could go stale.

So the precondition holds, and it holds for a reason worth restating precisely: every one of these three surfaces is either discarded per-session, refetched whole on the triggers that already exist, or re-derived from a message fetch that was already going to happen for an unrelated reason.
There is genuinely nothing to reconcile, because nothing is kept long enough, or independently enough, to go stale.

## The real fork is not per-surface, it is one property

`message_ops` earned its complexity - a dense per-channel sequence, a cursor, gap detection, a snapshot fallback - because messages are an *unbounded, incrementally growing collection* where re-fetching the whole thing on every reconnect is not viable.
A channel can hold years of history; a cursor is what lets a client ask only for what it missed.

None of reactions, pins or polls share that property, and the reason differs per surface, which is why the answer below is not one shape reused three ways but two shapes, neither of them an op stream.

## Reactions: there is no delta to log, because the server never computes one

`Event::ReactionsChanged` (`crates/slimm-server/src/hub/event.rs`) carries only `channel_id` and `message_id` on the wire event itself - no tally, no reactor.
`http/ws/authorization.rs`'s dispatch reads `store.reactions_for_message(message_id, ctx.user_id)` fresh, per connection, at send time, and that per-viewer read is what keeps a blocked reactor's count off the blocking party's screen (see PR #147 ("Blocking, and the two halves of it a client cannot do")).

That means there is structurally no shared fact an op stream could record.
An edit op can carry the message's current content because content is the same for everyone; a reaction "op" would have to be either a global answer (reintroducing the blocking bug `tests/blocking_live.rs` already exists to catch) or a per-viewer answer, which cannot be written once and read by every future viewer the way a message op can.

If reactions were ever persisted - for offline availability, or to avoid a re-fetch on every channel open - the reconciliation shape already exists in this codebase and does not need inventing: `BatchProfilesController` (`client/packages/app/lib/src/features/members/providers/user_profiles.dart`).
It keeps no cursor over renames because none could exist; instead `SyncController.start()` clears the whole cache on every reconnect, and a live `Event::ProfileChanged` evicts one id in between.
A persisted reactions table would take the same two backstops: clear (or mark stale) on reconnect, since there is nothing to reconcile *from*, and let a live `ReactionsChanged` frame overwrite the one row it names, exactly as `MessageExtrasController._applyReactionsChanged` already overwrites the one map entry it names today.
The `reacted` flag would need no new handling either: it is already computed locally against `ctx.user_id` and never trusted from any other viewer's copy.

## Polls: the aggregate is a different shape from the vote, and only one of them needs a cache to reconcile

`Event::PollVoted` is not the same shape as `ReactionsChanged`.
It carries the full per-option tally on the event itself (`options: Vec<(i64, i64)>` in `hub/event.rs`), computed once in `http/polls.rs`'s `vote` handler and broadcast unfiltered to every connection - the same "whole current answer, not a delta" shape `ThreadUpdated` uses, and, like that event, not blocking-aware (a vote from someone the viewer has blocked still counts, the same pre-existing, separately-tracked behaviour CLAUDE.md already records for a thread's reply count).

`votedOption` - which option *this* viewer picked - is the other half, and it is never on the wire at all.
The client's own `applyLocalVote` is the only place it is ever set, as an optimistic echo of the vote the caller just cast; nothing else in the protocol ever answers "what did I vote."

So a poll's aggregate collapses into the reactions shape above (a live frame overwrites the one row it names; a persisted cache would clear-and-refetch on reconnect the same way), and `votedOption` needs no reconciliation design at all, because there is no server fact to reconcile against - it would be reconstructed by a fresh read the same way `MessageExtras.poll` reconstructs it today, or simply not survive a restart, exactly as it does not today.
Neither half needs an op stream.

## Pins: a bounded set with its own endpoint, never riding the message row

Unlike reactions and polls, a pin is not carried on `MessageDto` at all - `client/packages/api/lib/src/models_pins.dart`'s `PinnedMessage` is its own wire shape, fetched only from the pins endpoint, and a message fetch that happens to catch a client up on everything else says nothing about whether it is pinned.

`store/pins.rs`'s own module doc says pinning is "naturally idempotent" at the store layer - pinning an already-pinned message is a no-op that leaves the original pinner and timestamp in place.
CLAUDE.md's debt note called a pin "not idempotent by message id the way an edit or delete is," and that is true at a different layer: an edit or a delete happens to a message at most meaningfully once between two points in time (the latest content, or deleted-or-not), where a pin can toggle on, off, and on again, and each toggle is a real, distinct action with its own actor and timestamp - not a value that collapses to "the latest one, blank the rest" the way `message_ops` collapses a run of edits.

None of that ends up mattering, because a pin set is bounded at 200 (`MAX_PINS_PER_CHANNEL`) and is *already* cheap to refetch wholesale - which is exactly what `PinsController.refresh()` does today, on construction and on every live pin/unpin event, with no cursor of any kind.
If pins were ever persisted locally, the correct design is the same wholesale refetch, just written to a table instead of a `StateNotifier`: refetch the whole set on channel open and on reconnect, replace it whole on a live event, same as `channels` itself is "refetched whole on every sync" per `database.dart`'s own migration doc comments.
An op stream would be strictly worse here: it would have to record every toggle to stay correct, where a wholesale refetch only ever needs the current 200-row answer.

## Is an op stream ever right for any of the three? No, and the reason generalizes

The fork that decides whether a surface needs `message_ops`' machinery is not "does it change" or "is it per-message" - reactions, pins and polls are all of those - it is whether the collection is *unbounded and independently paged*, such that a wholesale refetch on every reconnect would be the wrong trade against a cursor.
Messages are; none of these three are.
Reactions and polls ride a message row that is already being caught up by `message_ops` for an unrelated reason, so their reconciliation is free once threaded through the same merge point.
Pins are a small, server-bounded set that was already being refetched wholesale before this record was written.

So the honest answer to the question this record exists to settle is: these should stay in memory, and if that ever changes, the fix is "clear-and-refetch on reconnect, overwrite-on-live-event" - the same shape this project already built once for author display names - never a second `message_ops`.

## The tripwire's real scope, and what it does not see

`local_schema_reconciliation_test.dart` reads `SlimmDatabase.allTables`, so it fails the moment a table is added to that one `@DriftDatabase` annotation, regardless of what the table is for or what it is named.
That is a strong, structural guarantee for its scope: it cannot be satisfied by a comment or a naming convention, only by the annotation actually changing.

Its scope is exactly that one recognized database, and only that one.
It would not fire if a future change cached reaction, pin or poll state through some other persistence mechanism entirely - `SharedPreferences` (already used in this client for local device settings, never for cached server state), a second drift database, or a plain file.
None of those exist in this client today; a repo-wide check confirmed the only local persistence surfaces are `SlimmDatabase` and `SharedPreferences`, and every `SharedPreferences` key currently written is a local-only preference with no server truth behind it.
Recorded here rather than silently trusted: the tripwire is a guarantee about one table list, not a guarantee about all client-side persistence, and whoever next reaches for a second local-storage mechanism should read this paragraph before assuming the existing test would have caught it.

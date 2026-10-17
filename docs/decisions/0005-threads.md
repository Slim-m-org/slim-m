# 0005 - Threads

Date: 2026-08-01.
Status: **built, 2026-08-01, under a stated assumption.**
Option 1 (a thread is a channel with a parent) is what shipped.
`channels.parent_message_id` references the message a thread hangs off, resolved live rather than copied.
Every place that lists, counts, or evaluates permissions for a channel was checked and either already worked unchanged or was given the one-line exclusion the option's own writeup predicted: `list_channels`, `reorder_channels`'s own query, `delete_channel`'s last-channel guard, and `channel_scopes_moderation`.
The owner had not explicitly confirmed the choice at build time.
The shape is additive - a nullable column, one new route, no changes to any existing wire type's meaning - and was judged safe to build ahead of that confirmation on that basis; see the PR for the full reasoning.
Nesting (a thread opened on a message that is itself inside a thread) is refused server-side, found during the build rather than anticipated by the writeup below.
The permission-inheritance mechanism resolves exactly one hop, and a second thread layered on top would have evaluated against the inner thread's own empty overwrite bucket instead of the real channel's, silently dropping whatever deny the real channel had set.
The rest of this file is the pre-build writeup, kept for the record of why option 1 won.

## Where this came from

Two reports came in close together, and they are really two different asks.
The first was "no reply mechanic either?", which is the small one: a message pointing at another message, with a compact quote above it you can tap to jump to the original.
That got built.
See `crates/slimm-server/migrations/0029_message_replies.sql` and `messages.replyToId` on the client.

The second was threads, and the owner named the model directly: "threads in my eyes are basically where we can reply to someone tightly, so we click reply in thread, it opens up a hidden sub channel and we communicate there, I like how slack does it."
That is not a bigger version of a reply.
A reply is a column on a message and a bit of client rendering.
A thread, done the way slack does it, is a hidden container with its own membership of messages, its own unread state, and its own place in push and search.
Picking the shape of that container is a schema decision, and it is the kind that is expensive to walk back once real messages are living inside it.
So this got written up instead of built.

## Option 1: a thread is a channel with a parent

`channels` gains a nullable `parent_channel_id`, a self-reference the same shape `messages.reply_to_id` just got.
A thread's messages are ordinary rows in the same `messages` table, in their own `channel_id`, with their own `channel_seq_counters` row - so they get a real per-thread `seq`, real keyset pagination, and a real per-thread cursor in `/sync`, all for free, because `/sync` already scopes by `channel_id` and asks nothing about what a channel's parent is.

Permissions come along the same way.
`permissions_in_channel` evaluates against whatever channel id it is handed, and a thread channel is just a channel, so `VIEW_CHANNEL` and `SEND_MESSAGES` on it can inherit the parent's overwrites (or be its own bucket, if the two ever need to diverge) with no new evaluator branch.
The WebSocket fan-out, push fan-out, and full-text search are all keyed on `channel_id` too, so a thread message reaches a viewer, wakes a push, and shows up in search through the exact same code every other message already goes through.

The cost is that "every channel is a top-level thing the rail shows" stops being true, and that assumption is not in one place.
It is checked, not guessed: `Store::list_channels` already filters `kind != 'dm'` to keep a DM out of the rail, and a thread needs the same filter added, `parent_channel_id IS NOT NULL`.
`Store::delete_channel`'s guard against removing a deployment's last channel counts `WHERE deleted_at IS NULL AND kind != 'dm'` - today that count is exactly the rail's contents, and a thread inflating it would let someone delete the deployment's one real channel while a handful of threads on it still exist, which the guard exists specifically to stop.
Both are one-line fixes once you know to look, and the reason to write this down is that a future contributor adding a third "count the channels" query has no way to know it needs the same filter unless it is named somewhere.

What does not walk back: once thread rows exist inside `channels`, every future feature that touches channel counting, ordering, or listing inherits the obligation to ask "is this a thread" - forever, not just at ship time.
Migrating away from this shape later, if it turned out wrong, means moving every thread's messages into whatever the new container is, which is a real data migration against a live table, not a code change.

## Option 2: a thread is a new table, keyed to a root message

A `threads` table, one row per thread, with `root_message_id` and its own message stream - either a `thread_id` column added to `messages` alongside `channel_id`, or a second table shaped like `messages`.

This is the one CLAUDE.md's own reconciliation writeup already argues against, and it is worth quoting rather than restating: "a second authority over one fact is the seam the canvas's own module doc names as its worst residual."
A thread needs its own ordering, because `/sync`'s cursor is per `channel_id` and a thread is not a channel here, so it needs its own cursor dimension - a third thing to catch up alongside a channel cursor and an op cursor, on a wire protocol that has only ever had one.
Unread state is `(user_id, channel_id)` today; a thread needs `(user_id, thread_id)` beside it, doubling that surface.
Push fan-out evaluates permissions per channel; a thread message needs its own variant of that evaluation, because a thread has no `channel_id` of its own to hand the existing one.
The WebSocket hub's events are all `channel_id`-scoped; every one of `MessageCreated`, `MessageEdited`, `MessageDeleted` and the authorization check in `http/ws/authorization.rs` needs a thread-aware branch.
Search has no thread column in the FTS index at all, so a thread message search is new surface, not a filter added to old surface.

What does not walk back: this is a second ordering authority the day it ships, and every one of sync, unread, push and search has to learn it exists.
If it turns out wrong, unwinding it means the same data migration option 1 would need, except now there are two independent things to reconcile into one instead of one thing to relabel.

## Option 3: threads are replies with a filtered view

No new container at all.
A thread view is a client-side query: given a root message id, show only the messages that reply to it (or reply to something that replies to it).
Almost nothing to build - the reply graph already exists the moment replies ship - and nothing here is destructive, since it is a read, not a schema.

The real cost is that it is not what the owner described.
Slack's threads are a hidden side-channel: a reply in a thread does not sit inline in the main channel, does not add to the main channel's unread count, and shows as a collapsed "3 replies" bubble until you open it.
A filtered view over ordinary replies does none of that.
The replies still render inline in the main transcript, just with a quote above them; there is no collapsed summary, no separate unread count, and nothing hidden.
It would ship something that looks like it answered the ask and does not match the model the owner actually named, which is a worse outcome than admitting the cheap option does not fit.

## Recommendation

Option 1.
It is the only one of the three that reuses permissions, sync, push and search rather than teaching each of them a new dimension, and the places it does need a code change - `list_channels`, `delete_channel`'s guard, anywhere else that counts or lists channels - are findable by grep rather than scattered across the whole reconciliation surface the way option 2's would be.
Option 3 is close to free and is worth remembering as a fallback if the owner decides a lighter version is fine after all, but it should be chosen knowingly, not shipped as a stand-in for the real thing.
Option 2 repeats a mistake this project has already found and fixed once, in the same file this decision follows up: a second authority over one fact.

Not decided here: whether a thread's `VIEW_CHANNEL`/`SEND_MESSAGES` inherit the parent's overwrites or carry their own, whether a thread needs its own entry point beyond "reply in thread" (a dedicated open-thread affordance, ~~a reply count on the parent message~~), and whether push for a thread reply should behave like an ordinary channel message or more like a targeted mention.
Each of those is a smaller decision that only needs making once option 1 (or whichever option) is picked.
The struck one is decided and built, 2026-08-01: `Store::thread_summaries_for_messages` batch-loads a reply count and a last-reply timestamp onto the parent message, the same one-query-per-page shape `thread_channel_id` itself already used, and `ThreadReplySummary` (`client/packages/app/lib/src/features/messages/widgets/message_row_parts.dart`) renders it as a tap-through "N replies" line. See CLAUDE.md's own note on the same date for what the count's permission story and the deleted-reply exclusion turned out to need.

~~Deliberately not built: a live "thread opened" push for a bystander already viewing the parent message.~~
Built 2026-08-02: `Event::ThreadUpdated` (`crates/slimm-server/src/hub/event.rs`) fires when `Store::open_thread` creates a channel for the first time and again whenever a reply lands in one, folded into the same channel-scoped `VIEW_CHANNEL` gate every other channel event already uses in `http::ws::authorize`, keyed on the *parent* channel's id rather than the thread's own.
It carries the current `reply_count`/`last_reply_at` directly rather than re-deriving them per receiving connection the way `ReactionsChanged` does its tally: the batch load a REST fetch already uses for this same number is not per-viewer filtered either (blocking does not touch it), so precomputing it here does not reintroduce the bug that fix closed.
An offline client still needs no catch-up machinery of its own: `thread_channel_id` and the reply count are already batch-loaded onto `MessageDto` on every fetch, so a client that missed the live frame learns the same answer on its next list, search or sync of the parent channel.
See CLAUDE.md's own note on the same date for the mutation-tested proof that a viewer denied on the parent learns nothing.

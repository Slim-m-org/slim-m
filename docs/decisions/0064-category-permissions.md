# 0064 - Category permissions, by syncing channels to their category

Status: accepted, 2026-10-13.

## The problem

The owner asked for "permissions on categories? maybe an entire category is role based" (2026-10-13).
Until now a category carried no permission of its own (see docs/IMPLIED-GAPS.md): making a whole section staff-only meant editing every channel in it, and every new channel filed there started open.

## The model

A category has its own overwrites, the same shape as a channel's: an allow and a deny per role or member.
Each channel has a `permissions_synced` flag.
A synced channel's overwrites are an exact copy of its category's.

- Saving a category's overwrites copies them into every synced channel in it, in the same transaction.
- Saving a channel's own overwrites un-syncs that channel; "Sync with category" copies the category's back and syncs it again.
- A channel created in a category starts synced with a copy of its overwrites; one created with its own audience (a private channel with picks) starts unsynced.
- Moving a channel never changes who can see it: it keeps its overwrites and stops being synced, and "Sync with category" adopts the new category's. Deleting a category leaves its channels the same way.
- A channel outside any category is never synced.

## Why copy, not layer

The alternative is evaluating category overwrites underneath channel ones on every check.
That touches every permission path (single-channel checks, batch checks, push fan-out, the channel list, the restricted flag), each with its own query shape, and every one would have to stay consistent.
Copying keeps the evaluator, its tests and its performance exactly as they are: a category only ever changes which rows a channel holds, through the same write path an admin's own edit uses, and the same `OverwriteChanged` event tells clients.
It is also the model members already know from Discord, where "synced with the category" is a visible state.

## What a member sees

A category is listed to a member only when it holds a channel they can view (or they manage channels), so a staff-only category's name stays with staff.

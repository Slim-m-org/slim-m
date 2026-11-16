# 0006 - Channel categories are containers, not the channel's type

Status: accepted, 2026-08-03.
Raised by the owner in the `backlog` channel (item #34).
The one call that needed confirming was the permission question below, and the owner confirmed it: "no permissions for categories is fine".

## The report

> the text \ voice are not just categories for sorting, they control where i put my text and voice channels, which is not what i wanted, text/ voice should be categories/folders that contain whatever type of channel we want, meaning If i create a channel of type VOICE, I should have been able to drag it into the voice section or the text section but I am not able too

## What is actually true today

There are no categories.
`channel_rail.dart` renders two hardcoded sections whose contents are `.where((c) => c.kind == 'text')` and `.where((c) => c.kind == 'voice')`.
The headers read "Text" and "Voice" because that is the filter, not because anything groups channels.

So a channel's `kind` is doing two unrelated jobs at once: deciding how the channel behaves (a transcript or a call) and deciding where it appears in the rail.
The owner wants only the first.
Nothing needs to change about `kind` itself; what is missing is the second fact, which has never been stored.

## The model

A new table, and one nullable column.

```sql
CREATE TABLE channel_categories (
    id         BLOB PRIMARY KEY,
    name       TEXT NOT NULL,
    position   INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    deleted_at INTEGER
) STRICT;

ALTER TABLE channels ADD COLUMN category_id BLOB REFERENCES channel_categories(id);
```

`kind` keeps deciding behaviour and stops deciding placement.
`category_id` decides placement and nothing else.
These are two different facts, so storing both is not the "second authority over one fact" seam this project's canvas notes warn about - it is the opposite, splitting one column that was carrying two meanings.

**The upgrade must be invisible.**
The backfill creates a "Text" and a "Voice" category and assigns every existing channel by its current `kind`, so a deployment that upgrades sees exactly the rail it had before and can then move things.
This mirrors `0028_channel_position_backfill.sql`, which assigned sequential positions in the existing display order for the same reason.

**A channel with `category_id IS NULL` is uncategorised** and renders in an implicit section above every named category, the way Discord does.
That is what a channel falls back to when its category is deleted - deleting a category must never delete the channels inside it.

## Ordering

`channels.position` becomes position *within* a category rather than across the whole rail.
`channel_categories.position` orders the categories themselves.

This changes the reorder contract, and that is the part worth reviewing carefully.
`Store::reorder_channels` currently takes one flat list and **refuses it unless it is exactly the set of live non-DM, non-thread channels**, so a caller always learns whether its drag took effect.
That validation is worth keeping, so the payload becomes a list of (category, ordered channel ids) covering every live channel exactly once, validated as one set the same way.
A drag between two sections is then one request that reassigns and repositions atomically, rather than a move followed by a reorder that could half-apply.

## Permissions are deliberately not inherited in v1

Discord lets a category carry overwrites that its channels inherit.
That is a second resolution dimension on top of the one-hop thread resolution `Store::permission_channel` already does, and getting it wrong is a silent read leak rather than a visible bug - exactly the failure this project has already had twice, when `evict_from_voice` and `channel_scopes_moderation` each went stale against a channel kind that arrived later.

So a category is organisational only: it groups and orders, and it grants and denies nothing.
Recorded in `docs/IMPLIED-GAPS.md` rather than left for someone to assume, because "categories exist" reads as "category permissions exist" to anyone arriving from Discord.

## The four places that will drift if they are not changed together

This project's own history says the recurring bug shape here is a duplicated query that only one caller remembers to fix.
All four of these carry their own copy of the same predicate:

- `Store::list_channels` (`store/bootstrap.rs`) - `WHERE deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL ORDER BY position, created_at`. Ordering becomes category-then-position.
- `Store::reorder_channels` (`store/channel_order.rs`) - carries a **second, independent copy** of that exact query for its validation read. It needed the identical one-line fix when threads landed and it needs one again here.
- `Store::delete_channel`'s last-channel guard counts `WHERE kind != 'dm'`. Categories do not change what a channel is, so this guard is unaffected - confirmed rather than assumed, and worth a test that says so.
- The client's `replaceChannels` prunes anything absent from the server's list. A category is not a channel and never appears there, so the local category table needs its own replace path, not a shared one.

## Live updates

There is still no `channel.created` event anywhere in the wire protocol; the client infers one and refetches (`_refreshChannelsOnce`).
Categories should not add a third mechanism.
`ChannelRefresher.refresh()` already re-fetches the whole list on any role, overwrite or channel-list event, so a category change publishes an event that lands in that same path and the rail corrects itself with no new machinery.

## Routes

All gated on `MANAGE_CHANNELS`, the same bit channel create/rename/delete already uses.

- `GET /channels` gains `category_id` per channel, and the response gains the category list.
- `POST /categories`, `PATCH /categories/{id}` (rename, reposition), `DELETE /categories/{id}` (its channels fall back to uncategorised).
- The reorder route's body carries the grouped shape described above.

Adding a route means the matching `schema/openapi.yaml` edit and a `tests/response_contract` case in the same change, or `cargo test` fails.

## What this does not do

Nested categories, collapsing a category (a client-side preference, separate), per-category permission overwrites, and a default category for newly created channels beyond "uncategorised".
Since then, [0064](0064-category-permissions.md) added per-category permission overwrites and [0120](0120-nested-categories.md) nested categories two levels deep.

<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0120 - Categories nest two levels deep

Status: accepted, 2026-11-16.
Builds on [0006](0006-channel-categories.md), which listed nested categories as not done, and [0064](0064-category-permissions.md), whose copy model this extends one level up.
Ships inside PR #2412 (`b22/integration`).

## The ask

> can we support multi level categories? so i can do like a gamers/{minecraft/cs2} category and each of those is hidden by roles so if they have a gamer role they see that category and if they have a cs role they see cs2 category with its respective channels

The owner settled three points on 2026-11-16.

- Two levels only: a top-level category may hold sub-categories, and a sub-category may not hold its own.
- A channel lives directly in a top-level category, directly in a sub-category, or uncategorised, as today.
- Someone with the cs role but not the gamer role sees "gamers > cs2" and cs2's channels, with gamers shown only as a container and none of gamers' own channels.

That last point widens 0064's rule from "a category is listed when it holds a channel the member can view, or they manage channels" to "a category is listed when it or one of its sub-categories holds a channel the member can view, or they manage channels".

## Data model

`channel_categories` gains two columns, and nothing else changes shape.

- `parent_id` names the top-level category a sub-category sits in, and is null for a top-level category, so every existing row stays exactly where it is.
- `permissions_synced` is 0064's channel flag one level up: whether a sub-category's overwrites are a copy of its parent's.
  It is always 0 on a top-level category, the way a channel outside any category is never synced.

`channels.category_id` keeps its meaning: it names whichever category, at either level, the channel sits directly in.
A channel in cs2 carries cs2's id, never gamers'.

### Two levels, enforced by the server

The store refuses each of these inside the same `BEGIN IMMEDIATE` transaction as the write, so two concurrent moves cannot combine into a third level.

- A parent that is not a live category is a 400, the same shape as `createChannel`'s unknown category.
- A category named as its own parent is a 400.
- A parent that is itself a sub-category is a 409.
- Filing a category that still has live sub-categories under another one is a 409.

Three triggers in migration 0193 hold the same line for any later writer that forgets to ask, such as an import.
They are a backstop: the store's checks run first and give the client a readable answer, so a trigger firing means a store bug.
The third one also refuses soft-deleting a category that still has live sub-categories, so a delete has to move them out first.

### Ordering

`channel_categories.position` becomes a sort key among siblings: among the top-level categories when `parent_id` is null, and among one parent's sub-categories otherwise.
A create appends after the last live sibling, read inside the write transaction the way a create already does.
`channels.position` is unchanged: a sort key among the channels sitting directly in one category.

A top-level category renders its own channels first and its sub-categories after them, never interleaved.
With interleaving, a channel row after a sub-category's last row could belong to either the sub-category or its parent, and nothing on screen would say which.
With this rule every row belongs to the nearest heading above it, which is also how the touch reorder list already attributes a dropped channel (`groupsFromRailItems`).

The server's listings follow the same tree order: uncategorised channels first, then each top-level category by position with its own channels, then each of its sub-categories by position with theirs.
Ties break on `created_at` and then id at every level, so two siblings that share a position never interleave their children.

### Moving a category

A category moves by `PATCH /categories/{id}` with `parent_id`, which is one move appended after its new siblings, or by `PUT /categories/order`, which is a whole arrangement at once and what a drag sends.
Moving never changes who can see anything: the moved category keeps its overwrites and stops being synced, and its channels keep theirs.

### Deleting a category

Deleting a category never deletes what is in it, which generalises 0006: everything moves up one level, in the same transaction as the soft delete.

- A deleted sub-category's channels move into its parent, after the parent's own channels and in their existing order.
- A deleted top-level category's own channels fall back to uncategorised, exactly as today.
- A deleted top-level category's sub-categories become top-level categories in the slot it held, in their existing order, with the other top-level positions renumbered around them.

Every channel and category moved this way keeps its overwrites and stops being synced, matching 0064's "deleting a category leaves its channels the same way".
Nobody's view of any channel changes, so a delete publishes `CategoryChanged` and no overwrite event.
Cascading the delete down to the sub-categories was rejected: it would silently flatten a structure the admin built and discard the sub-categories' overwrites, which are the audience every new channel in them starts from.

### Migration 0193

```sql
-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Nested categories (decision 0120): a category may sit under one top-level
-- category, two levels at most. A null parent_id is a top-level category, so
-- every existing row stays where it is.
ALTER TABLE channel_categories
    ADD COLUMN parent_id BLOB REFERENCES channel_categories(id);

-- Decision 0064's channel flag one level up: whether a sub-category's
-- overwrites are a copy of its parent's. Every existing category is top-level,
-- and a top-level category is never synced.
ALTER TABLE channel_categories
    ADD COLUMN permissions_synced INTEGER NOT NULL DEFAULT 0
    CHECK (permissions_synced IN (0, 1));

CREATE INDEX channel_categories_parent ON channel_categories(parent_id)
    WHERE parent_id IS NOT NULL;

-- The store refuses a third level with a readable error first; these refuse
-- it for any writer that forgets to ask.
CREATE TRIGGER channel_categories_two_levels_on_insert
BEFORE INSERT ON channel_categories
WHEN NEW.parent_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a category nests two levels at most')
    WHERE NEW.parent_id = NEW.id
       OR NOT EXISTS (
           SELECT 1 FROM channel_categories p
           WHERE p.id = NEW.parent_id
             AND p.parent_id IS NULL
             AND p.deleted_at IS NULL
       );
END;

CREATE TRIGGER channel_categories_two_levels_on_update
BEFORE UPDATE OF parent_id ON channel_categories
WHEN NEW.parent_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a category nests two levels at most')
    WHERE NEW.parent_id = NEW.id
       OR NOT EXISTS (
           SELECT 1 FROM channel_categories p
           WHERE p.id = NEW.parent_id
             AND p.parent_id IS NULL
             AND p.deleted_at IS NULL
       )
       OR EXISTS (
           SELECT 1 FROM channel_categories c
           WHERE c.parent_id = NEW.id
             AND c.deleted_at IS NULL
       );
END;

-- A delete moves its sub-categories to the top level before the row goes.
CREATE TRIGGER channel_categories_delete_moves_children_out
BEFORE UPDATE OF deleted_at ON channel_categories
WHEN NEW.deleted_at IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'move its sub-categories out before deleting a category')
    WHERE EXISTS (
        SELECT 1 FROM channel_categories c
        WHERE c.parent_id = NEW.id
          AND c.deleted_at IS NULL
    );
END;
```

No backfill is needed: every existing category becomes a top-level one that is not synced to anything.

Writing a whole arrangement under these triggers needs one order of statements.
First clear `parent_id` on every category whose parent changes, then set each new non-null parent.
Setting the new parents first can trip the update trigger, when a category being filed under another still holds a child that the same arrangement moves elsewhere.

## Permission model

The evaluator still never reads a category.
A category only changes which `channel_overwrites` rows a channel holds, and now which `category_overwrites` rows a sub-category holds, through the copy 0064 introduced.
Nothing reads `parent_id` when deciding what a member may do.

- A new sub-category starts synced with a copy of its parent's overwrites, written in the same transaction as the create, the way a channel created in a category starts.
- Saving a top-level category's overwrites copies them into every synced channel sitting directly in it, into every synced sub-category, and on into every synced channel of those synced sub-categories, in one transaction.
- The copy stops at the first unsynced hop: an unsynced sub-category keeps its own overwrites, and the synced channels inside it keep the copy they already hold.
- Saving a sub-category's own overwrites un-syncs it from its parent and copies the result into its own synced channels.
- "Sync with parent" (`POST /categories/{id}/overwrites/sync`) copies the parent's overwrites back into the sub-category, marks it synced, and cascades into its synced channels.
- A channel created in a sub-category copies the sub-category's overwrites, through the existing `copy_category_overwrites` path, unchanged.
- Moving a category, deleting its parent, or promoting it never syncs it to anything, and "Sync with parent" is the only way back.
- The cascade is an internal copy that never un-syncs the sub-category it writes into; only an admin's own save of a sub-category does that.

Escalation follows 0064.
A parent save is checked entry by entry against the caller's deployment permissions, as today, and the cascade copies exactly what passed that check, since a synced sub-category already held the parent's previous rows.
"Sync with parent" refuses unless the caller holds every bit the parent allows, the same rule the channel sync applies to its category.
It also refuses when the sync would drop a deny of the sub-category's that the parent lacks and the caller does not hold, since a batch edit counts lifting a deny as granting it.

Every channel a write touched publishes `OverwriteChanged`, with its `previously_visible_to` snapshot taken before the write.
One store query lists "the synced channels beneath this category", the direct ones and those of its synced sub-categories, and both the snapshot and the write use it, so the two cannot disagree about which channels changed.

## What a member sees

`GET /categories` lists one of two things.

- A caller whose deployment-level permissions hold `MANAGE_CHANNELS` gets every live category at both levels, empty ones included, since an empty one is where they file the next channel or sub-category.
- Anyone else gets each category holding a channel they can view, plus the parent of each such sub-category, and nothing more.

The closure runs upward only.
A visible parent never makes its sub-categories visible: a gamer-role member who can view no channel in cs2 is never told cs2 exists.
A parent listed only because one of its sub-categories is visible is a container: the member sees its name and none of its channels, because `GET /channels` was always filtered per channel and nothing about it changes.
So every listed sub-category's `parent_id` names a category in the same response.

Listing the parent is a disclosure, and it is the one the owner chose: anyone who can view a channel in a sub-category learns its parent's name.
An admin who files a public sub-category under a staff-only parent shows that parent's name to everyone, so the parent's permissions sheet says so in one line.

`GET /channels` and every channel frame stay filtered per channel and carry `category_id` exactly as they do today.
A temporary voice room counts as a channel for this rule, and it holds its lobby's overwrites, so it can never make a category visible to someone the lobby is hidden from.
Every write to a lobby's rows, copied down from a category or edited on the lobby itself, rewrites its live rooms' rows in the same transaction and publishes `overwrite.changed` for each room.
A room is never in a category save's synced set, even after a sync of its own, because it follows its lobby instead.

## Wire changes

Every change is additive.

- `ChannelCategory` gains `parent_id` (`[string, "null"]`, uuid), always present from this version and null on a top-level category.
  It is absent from older servers, which a client reads as "this server does not nest", the same convention `Channel.category_id` documents.
- `ChannelCategory.position` is redescribed as the sort key among its siblings.
- `CreateCategoryRequest` gains optional `parent_id`, and absent or null creates a top-level category.
  A retry with an id already used returns the stored row as today, whatever `parent_id` it sends.
- `UpdateCategoryRequest` gains optional `parent_id` with three states: absent leaves the placement alone, null moves the category to the top level, and an id files it under that top-level category.
  A `position` sent with it is the place among the new siblings, and without one the category is appended.
  At least one of `name`, `position` and `parent_id` is required.
- `createCategory` and `updateCategory` gain a 409 for the two depth refusals, and an unknown, deleted or self parent stays a 400.
- `deleteCategory` is redescribed: its contents move up one level.
- New `PUT /categories/order` (`reorderCategories`, MANAGE_CHANNELS, one Write token) takes `{ "groups": [{ "parent_id": null, "category_ids": [...] }, { "parent_id": "<id>", "category_ids": [...] }] }`, naming every live category exactly once.
- In that body, every non-null `parent_id` must be a category named in the null group, which is the whole depth rule for an arrangement.
  A mismatch is a 400 naming the missing and extra ids, as `PUT /channels/order` does, a repeated or unknown parent is a 400, and a depth breach is a 409.
- That route applies in one transaction, answers every category in tree order, and publishes one `category.changed` only when something actually moved.
- New `POST /categories/{categoryId}/overwrites/sync` (`syncCategoryOverwrites`, MANAGE_ROLES) is a 409 on a top-level category and answers `ChannelOverwrites` with `synced: true`.
- `ChannelOverwrites.synced` is now also present on a sub-category's own list, meaning whether it follows its parent, and stays absent on a top-level category's.
- `batchSetCategoryOverwrites` is redescribed: saving a top-level category cascades to its synced sub-categories and their synced channels, saving a sub-category un-syncs it, and each touched channel gets an `overwrite.changed`.
- `listCategories` is redescribed with the upward rule above, and its answer comes in tree order.

No new frame type is needed.

- `category.changed` stays payload-free and broadcast, and fires on a fresh create, a rename, a reposition, a re-parent through either route, and a delete with the moves it makes.
- `overwrite.changed` fires once for each channel a cascade, a sub-category save or a sub-category sync touched.
- `channel.updated` keeps firing for each channel `PUT /channels/order` moved, which may now be into or out of a sub-category.

The space export's `categories.jsonl` gains `parent_id`, and `audited_routes.rs` gains `category.reorder` (named like `channel.reorder` and `role.reorder`) and `category.overwrites_sync` rows.

### Mixed versions

An older client ignores `parent_id`.
It renders every category it is listed as a top-level section, sorted by a position that now repeats across sibling groups, so its order looks shuffled.
It is listed exactly the categories a newer client is, because the filtering is server-side, so nothing it shows is a leak.
An older manager client still reorders categories with one `PATCH` per category carrying a flat index, which keeps every sibling group's relative order, the same argument `reorder_channels_flat` makes for channels, and never touches `parent_id`.
A newer client on an older server finds no `parent_id` key and offers no nesting action, so it never asks an old server for a sub-category that would quietly be created at the top level.

## Server

- `store/models.rs`: `ChannelCategory.parent_id`.
- `store/categories.rs`: `list_categories` in tree order with `parent_id`; `create_category_with_id` takes a parent, checks it, copies its overwrites and marks the new row synced; `update_category` takes one parameter struct, runs in one write transaction, and answers a typed error for each refusal; `delete_category` moves contents up one level, sub-categories before the soft delete.
- A new `store/category_order.rs` beside `store/channels/channel_order.rs` holds the arrangement write, validated the same way and written in the two-phase order above.
- `store/category_overwrites.rs`: the cascade, the un-sync on a sub-category's own save, `synced_channels_beneath`, the sub-category sync, and the synced flag for a sub-category's overwrite list.
- `store/bootstrap.rs::list_channels` and `store/export_space.rs` order by the tree, because `ORDER BY cc.position` alone would sort a sub-category by its position among siblings as if it were top-level.
- `http/categories.rs`: `parent_id` on the DTO (always serialized), parsed on create and on PATCH with the present-or-null deserializer `http/space.rs` already uses, and the upward closure in `list`; the arrangement route goes in its own module.
- `http/category_overwrites.rs`: the before snapshot over `synced_channels_beneath`, `synced` on a sub-category's list, and the sync route.
- Every manage check runs before any read of the body's ids, so a caller without the permission learns nothing from a 400 versus a 404.
- Then `schema/openapi.yaml`, `audited_routes.rs`, the `CategoryChanged` doc comment in `hub/event.rs`, `scripts/lock-migrations.py`, and `cargo sqlx prepare --workspace -- --all-targets`.

## Client

### Rendering

- One pure builder, `CategoryTree` in `category_tree.dart`, turns the flat rows into the rail's sections in tree order, each with a depth of 0 or 1, and `orderedChannels` (next and previous channel) walks the same order.
- A sub-category's header is inset by `kRailRowInset`, the same edge as its parent's channel rows, and its channel rows by twice that, so every row still hangs off its own heading.
- The insets are the same at every width, since tokens never move with width.
- A sub-category whose parent this device does not hold renders as a top-level section until the next refresh, never under whichever heading happens to precede it.
- For someone who cannot manage channels, a top-level section stays when it or any of its sub-categories holds a channel, and a sub-category stays when it holds one.
- Without that last rule a container-only "gamers" would vanish, and cs2's indented heading would read as part of the block above it.

### Collapse

- The per-device set of collapsed ids is unchanged and covers both levels.
- Collapsing a parent hides its own rows and every sub-category beneath it, and expanding it again restores each sub-category's own state.
- A folded parent's dot rolls up its sub-categories' channels too.
- A row that would light (selected, unread or mentioned) still surfaces under a folded parent, beneath its own sub-category heading when it has one.
- Collapsed rows stay zero-height items, as today, so a reorder payload still names every channel.

### Moving things at pointer widths

This is `DesktopRailReorder`.

- A carried channel can land in any expanded section at either depth, and the insertion line is inset to the depth it lands at.
- Lifting a top-level category carries its whole block, sub-categories included, and lifting a sub-category carries its own block.
- A carried category is offered the top-level gaps and the sub-category gaps of every other expanded top-level block, which is how it gets filed under one.
- No category is ever offered a gap inside its own block.
- Where the last gap of a block and the next top-level gap share a line, the side the pointer is on decides: above it stays inside the block, below it starts the next one.
- A gap that would make a third level is still offered, marked refused: any gap inside a sub-category's block, and every sub-category gap for a carried category that has sub-categories of its own.
  The line there is danger-toned, inset to the third level, with "Two levels at most" beneath it and a not-allowed cursor, and a drop on it sends nothing.
  Silently snapping to the nearest legal gap was the first design; it left a manager guessing why the category did not land where they let go.
- An older server, one whose listing carries no `parent_id`, is offered top-level gaps only.
- A category drop sends one `PUT /categories/order`, and a channel drop sends `PUT /channels/order` as today.
- The server refuses a third level regardless, and that refusal lands in the rail's existing reorder error state.

### Touch, the phone sidebar, and keyboards

At compact width the rail is `channel_rail_drawer`, which is this same widget with the same insets (docs/design/desktop-vs-mobile.md).

- Channels keep hold-then-move across every section, and a channel dropped between a parent's heading and its first sub-category heading lands directly in the parent (translation table, "drag to reorder").
- Headers stay unliftable on touch, as today, and a long press opens the header menu instead (rule 1).
- Sub-category headers are 44dp touch rows that fold on tap, like top-level ones (law 2).
- "Create sub-category" and "Move into" open `showAppSheet`, a bottom sheet under 600 and a centred dialog above it, never a long menu (rule 4).
- The keyboard and screen-reader channel steps walk the flattened sections and skip everything under a collapsed parent, and the header steps move a category among its siblings only.

### The header menu, for a manager

- "Create sub-category..." appears on a top-level header when the server nests.
- "Move category up" and "Move category down" move it among its siblings.
- "Move into..." appears on a category with no sub-categories and lists every other top-level category in a sheet, and "Move out of gamers" appears on a sub-category.
- "Permissions..." opens the same grid, and a sub-category's adds a sync line: "Follows its parent category's permissions." or "Has its own permissions." with "Sync with parent category".
- A top-level category's permissions caption says that channels and sub-categories following it get these permissions, and that anyone who can see a channel in one of its sub-categories also sees its name.
  It does not list which sub-categories follow it, which would cost one request per sub-category each time the sheet opens.
- "Delete category..." says where the contents go: up into the parent for a sub-category, and for a parent, that its sub-categories become categories of their own.

### Elsewhere in the client

- The command palette, the channel permission picker and the create-channel sheet name a channel's place as "gamers / cs2".
- "Mark all as read" on a parent covers the sub-category channels this device holds.
- A `channel.created` or `channel.updated` naming a category this device does not hold, or one whose parent it does not hold, triggers the same refresh `category.changed` does.
- That also fixes a gap that exists today: a public channel moved into a category the member was never listed disappears from their rail until the next refresh.
- `api`: `ChannelCategory.parentId` and whether the key was present, `createCategory(parentId:)`, `moveCategory`, `reorderCategories`, `syncCategoryOverwrites`, and the synced flag on a category's overwrite set.
- `data`: `ChannelCategories.parentId`, drift schema 31 with an `_addColumnOnce` step, and `parent_id` written by both `replaceCategories`, its `DoUpdate` included, and `upsertCategory`.
- `CategoryOrderController` sends one `PUT /categories/order` instead of one `PATCH` per category on a server that nests.
  An older server has no such route, so there it keeps the per-category `PATCH` path for top-level order, partial-failure handling included.
- A refused arrangement or move stays in that controller and shows inline over the rail with a retry, like a refused channel reorder, never in a SnackBar.
- The create-category sheet gains a "Parent category" choice on a server that nests, and "Create sub-category..." opens it with the header already chosen.

## Ways this could leak a hidden category or channel name

1. Closing the visible set downward: listing a visible parent's sub-categories would tell a gamer-role member that cs2 exists.
   The closure adds parents of visible categories only.
2. Deciding "manages channels" from any channel's permissions rather than the deployment-level ones would list every category to someone granted MANAGE_CHANNELS on a single channel.
3. Cascading into an unsynced sub-category would overwrite an admin's cs-only cs2 with gamers' wider rows and expose cs2's channels to every gamer.
   Both hops check `permissions_synced`.
4. A cascade whose `OverwriteChanged` set misses the channels of synced sub-categories leaves a member who just lost access holding those channels and the sub-category's name in their cache and rail, and never tells a member who gained access.
5. Syncing anything as a side effect of a move, a parent delete or a promotion would hand a hidden sub-category or channel its new parent's wider audience.
   None of those paths sync.
6. A new sub-category created with no overwrites instead of a copy of its parent's would make the first channel created in it public under a staff-only parent.
7. A sub-category delete that synced its channels to the parent, instead of keeping their own rows, would widen them to the parent's audience.
8. The parent's name reaches everyone who can view any sub-category channel, by design.
   A public sub-category under a staff-only parent discloses that parent's name, which the parent's permissions sheet states.
9. A `category.changed` frame that grew a name, id or parent would broadcast it unfiltered to every connection, so it stays payload-free.
10. Running a body's validation before the manage check would let a non-manager probe which category ids exist through 400 versus 404 answers.
11. `replaceCategories` updating only name and position would keep a stale `parent_id`, and a client that rendered a category it is no longer listed, rather than pruning it, would keep showing a name the server withdrew.
12. A client that filed a channel naming an unknown category under the nearest preceding heading would misattribute it; it must refresh instead, and never fill the gap from another cache such as the audit-log name map.
13. Sibling positions reveal that hidden siblings exist, through gaps between the positions a member is listed.
    That is a count, never a name, and it is already true of top-level categories and channels, so it is accepted here.
14. The admin audit log records a category's `name` from the create and rename bodies and is readable with MANAGE_SERVER alone.
    That path predates nesting and this change does not widen it.
15. The space export holds every category with its `parent_id`, and it needs ADMINISTRATOR, which already reads every channel.

## Tests

- A cs-only member is listed gamers and cs2, not minecraft, sees only cs2's channels, and every listed `parent_id` is itself listed.
- A gamer-only member is listed gamers and minecraft, never cs2, and someone with neither role is listed neither.
- A manager is listed every category at both levels, empty ones included, while someone holding MANAGE_CHANNELS on one channel only gets the filtered list.
- Every depth refusal holds on create, PATCH and `PUT /categories/order`, and so do the triggers, driven straight at the database.
- Deleting a parent promotes its sub-categories into its slot with their overwrites and unsynced, leaves their channels and their sync untouched, and uncategorises its own channels.
- Deleting a sub-category moves its channels to the end of its parent with their overwrites and unsynced.
- A parent save reaches a synced sub-category and its synced channels, skips an unsynced one, and publishes `OverwriteChanged` for every touched channel with a correct `previously_visible_to`.
- A sub-category save un-syncs it, its sync adopts the parent's rows, and the sync refuses a caller lacking a bit the parent allows.
- A move un-syncs the moved category, keeps its rows, and publishes one `CategoryChanged`.
- `list_channels` and `list_categories` come back in tree order, and an old client's flat PATCH positions keep every sibling group's order.
- The openapi contract, response contract, 400 and 429 coverage, and audit route cases cover the two new routes.
- On the client: the tree builder, the container-only parent for a non-manager, collapse at both levels, the drop gaps a carried category is offered, the payload of a nested drag, and the refresh on a frame naming an unknown category.

## What this does not do

A third level, which the owner ruled out.
Layered evaluation of parent and sub-category overwrites at check time, for the reasons 0064 already gives.
A per-viewer renumbering of positions to hide that hidden siblings exist.
Nesting in the Discord import, which stays flat because Discord's categories are flat.

<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Canvas slice two: removal, restore, and an op stream that owns the ordering

Final implementation plan.
Synthesised from three designs and three adversarial reviews.

**Spine: Design 1 (op-stream-first).** It is the only design that structurally closes the hole rather than mitigating it: every mutation allocates exactly one seq and writes exactly one op row, so the sequence is *dense over ops*, `after_seq` is a real cursor rather than a high-water mark over a sparse space, and `seq == cursor + 1` becomes a legitimate gap detector.
Everything the message path cannot do falls out of that one property.

**Grafted in, each because a judge showed it was stronger:**

| From | What | Why it wins |
|---|---|---|
| D3 | `restore` as a first-class verb, and ops carrying a client-minted id | Product judge: the first slice's lesson was "do not ship a permanent write behind a bit @everyone holds", and a permanent *destructive* write is that lesson one order worse. Op ids give exactly-once under a lost response, which state-transition idempotence cannot give a batched remove. |
| D3 | Batched remove, up to 64 ids in one op | The only atomic gesture undo. `splitStroke` makes one gesture N objects; N independent DELETEs leave a permanently half-erased gesture if the client dies mid-undo. |
| D2 | `UniformGrid` park by inverted infinities, not NaN | Verified against `spatial_grid.dart:118-125`: the overlap test is a *rejection* test, so all-comparisons-false means **kept**. D1's NaN park would have emitted every erased slot into every cull forever. |
| D2 | `_removedIds` tombstone set on the client | Protocol judge's named fix for the winner: an in-flight viewport page can resurrect an object the client has already been told to drop, permanently, with no later catch-up re-delivering the erase. |
| D2 | `before_seq` fencing on clear | D1's clear has no fencing token and is not retry-safe: a lost response, retried, wipes whatever was drawn in the interval. |
| D2 | A timed-out member may erase, not place | Refusing it makes a timeout's practical effect "lock the defacement in place", which is backwards. |
| D2/D3 | The op trail is never compacted | D1 compacted `canvas_ops` at 4,000 ops, which destroys the only record of who removed what. |

**Where the judges disagreed and I picked against one of them:** the client-cost judge's headline recommendation was to delete `UniformGrid`'s cell map entirely and keep only `queryLinear`.
The evidence is good (the spike measures the grid saving 11us per frame and costing an 8.5x regression when objects cluster, which is the normal way people use a shared board) and the conclusion is probably right.
It is not this slice.
Removing the index is a separate, self-contained change with its own before/after measurement, and bundling it into the removal slice means a regression in either one is diagnosed as the other.
Section 1 records it as an explicit follow-up with the numbers attached so it is not re-derived.

---

## 1. What ships and what does not

### Ships

- **`canvas_ops` becomes the canvas's single ordering authority.** Every mutation - place, remove, clear, restore - allocates one seq from `channel_seq_counters(channel_id, 'canvas')` and writes one op row in the same transaction.
  `canvas_objects` stays a transactionally maintained projection.
- **Per-object erase**, batched up to 64 ids per op, gated on authorship or `MANAGE_CANVAS`.
- **Clear**, fenced by a required `before_seq`, gated on `MANAGE_CANVAS`.
- **Restore**, which un-deletes exactly the objects a named remove or clear op took, gated on op authorship or `MANAGE_CANVAS`.
- **`GET /channels/{id}/canvas/ops`**, an ordered, pageable catch-up feed with an honest `reset`.
- **Three new socket events**, all channel-scoped and all gated on `USE_CANVAS` through an exhaustive classifier that replaces today's single-variant `matches!`.
- **`MANAGE_CANVAS` enforcement.** The bit already exists, is already in `Permissions::ALL`, is already mirrored client-side and is already offered in both the role editor and the overwrites editor.
  There is no `contains(MANAGE_CANVAS)` anywhere, so an operator can tick "Manage the voice canvas" today and it does nothing.
  This slice gives it its only meaning.
- **Client: a real `UniformGrid.remove`, document removal with tombstones, a cursor and catch-up loop, an eraser tool with hit testing, undo, and a clear control.**

### Does not ship, each with its reason

- **Move, resize and z-order.** `move_canvas_object` stays unreachable.
  It needs a drag interaction and per-frame index maintenance; the spike measured one oversized object spanning 81 buckets, so a drag touches 162 buckets per frame.
  Nothing here creates that pressure and nothing here forecloses it.
- **A sweep or hard delete of dead object rows.** Hard-deleting a dead row frees its id, and the id guard at `store/canvas.rs:169-179` is the only thing stopping a replayed placement resurrecting a moderator-erased stroke.
  A sweep has to keep the id, which means keeping a smaller tombstone, which is a design decision this slice should not make in passing.
  `canvas_ops` and dead `canvas_objects` rows therefore grow like `messages` grows: unbounded, at the rate limit, in the same growth class the deployment has carried since Phase 1. Named as a residual in section 11, not hidden.
- **Compaction of `canvas_ops`.** D1 proposed it and the product judge was right that it destroys the moderation trail: after the window, nothing durable says who removed what, which turns quiet patient erasure into an undetectable griefing path.
  The GET's reset branch still handles a floor, so a sweep can be added later without a wire change.
- **Deleting `UniformGrid`'s cell map.** Recorded above; the numbers are 26us linear against 16us grid at the 20,000 ceiling, 0.06% of a frame, against a 224.8us clustered worst case and 1.62M bucket entries oversized.
  Separate change, separate measurement.
- **`props` stripping on erase.** D1 and D2 both stripped it for the byte bound.
  Restore needs the bytes.
  Bytes are the cheaper thing to give up than reversibility.
- **A lifetime op ceiling per channel.** D1 proposed 500,000 with the operator remedy being "delete the channel", which is not a remedy.
  Messages have no such ceiling and this is the same growth class.
- **An escalation guard on `MANAGE_CANVAS`.** Every content verb in this codebase goes on the bit alone, and `MANAGE_MESSAGES` already lets a junior moderator delete an administrator's message with no containment check.
  Inventing an exception here would be the only one.
  Residual named in section 11.
- **Splitting `USE_CANVAS` into view and draw.** Its payoff is real (it would let `TIMEOUT_DENY` cover drawing structurally and delete the direct check) and its deny half is a security trap: an overwrite denying `USE_CANVAS` today means "no canvas at all", so a backfill that sets only the new view-deny quietly hands drawing back to somebody an operator shut out.
  Not in the same change as the removal path.
- **A canvas cursor in `POST /sync`.** The canvas cursor belongs to an open pane, not to an app session; putting it in `/sync` makes every client pay for a surface most of them never open, and makes `after_seq` mean two streams.
- **Local persistence of canvas objects.** The whole reconciliation design leans on a reset costing exactly one viewport read.
  A drift table takes that property away.
- **Telling a member their ink was erased.** All three designs ship removal as silent, matching `MessageDeleted`.
  Residual, section 11.
- **Selection, lasso, partial-stroke erase, erase-by-author, images, GIFs, camera bubbles, screen-share tiles, ephemeral in-flight ink, multi-user cursors.** Unchanged from slice one's deferral list.

---

## 2. The migration

`crates/slimm-server/migrations/0026_canvas_ops.sql`.
Forward-only.

**It touches no live data.** `canvas_objects` is not dropped, altered, or rewritten; its four indexes, its R-Tree and its three triggers are untouched.
`canvas_ops` is rebuilt, and the guard table is what turns "nothing has ever written to it" from an assumption into a refusal.

```sql
-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Rebuilds `canvas_ops` into the canvas's single ordering authority. The 0002
-- shape was one unconstrained `op TEXT` column and has never held a row on any
-- deployment: the only reference is the authorship anonymisation in
-- store/account_deletion.rs, which reads nothing. `canvas_objects` is
-- deliberately untouched, unlike 0015, which could rebuild it only because no
-- deployment held canvas rows yet.

DROP TABLE IF EXISTS canvas_ops_rebuild_guard;

CREATE TABLE canvas_ops_rebuild_guard (
    rows INTEGER NOT NULL CONSTRAINT canvas_ops_was_not_empty CHECK (rows = 0)
) STRICT;

INSERT INTO canvas_ops_rebuild_guard (rows) SELECT count(*) FROM canvas_ops;

DROP TABLE canvas_ops_rebuild_guard;
DROP TABLE canvas_ops;

CREATE TABLE canvas_ops (
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    id         BLOB NOT NULL UNIQUE,
    kind       TEXT NOT NULL,
    actor_id   BLOB REFERENCES users(id) ON DELETE SET NULL,
    bound_seq  INTEGER,
    target_op  BLOB REFERENCES canvas_ops(id),
    created_at INTEGER NOT NULL,
    PRIMARY KEY (channel_id, seq),
    CONSTRAINT canvas_op_kind
        CHECK (kind IN ('place', 'remove', 'clear', 'restore')),
    CONSTRAINT canvas_op_bound
        CHECK ((kind = 'clear') = (bound_seq IS NOT NULL)),
    CONSTRAINT canvas_op_target
        CHECK ((kind = 'restore') = (target_op IS NOT NULL))
) STRICT, WITHOUT ROWID;

CREATE TABLE canvas_op_targets (
    channel_id BLOB NOT NULL,
    seq        INTEGER NOT NULL,
    object_id  BLOB NOT NULL REFERENCES canvas_objects(id),
    PRIMARY KEY (channel_id, seq, object_id),
    FOREIGN KEY (channel_id, seq)
        REFERENCES canvas_ops(channel_id, seq) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

-- Recreated, not inherited: DROP TABLE took 0019's index with it.
CREATE INDEX canvas_ops_author
    ON canvas_ops(actor_id) WHERE actor_id IS NOT NULL;

-- Restore reads "which objects did that op name", so the child table needs the
-- reverse lookup its own primary key already serves; this one serves the
-- forward lookup from an object to the ops that touched it, which is what
-- account deletion and any future audit read.
CREATE INDEX canvas_op_targets_object ON canvas_op_targets(object_id);
```

Notes that are load-bearing:

- **`id BLOB NOT NULL UNIQUE` is the client-minted UUIDv7 idempotency key.** State-transition idempotence is sufficient for a single erase and insufficient for a batched one: a retried 64-id remove whose response was lost must not re-erase whatever a concurrent writer restored in between.
  An op id makes it exactly-once.
- **`WITHOUT ROWID` with `PRIMARY KEY (channel_id, seq)`** makes the feed's `channel_id = ? AND seq > ? ORDER BY seq` a range scan over the table's own b-tree with the payload inline.
- **The composite FK on `canvas_op_targets` is legal** because `(channel_id, seq)` is the parent's primary key.
  `foreign_keys(true)` is set at `db.rs:33`.
- **The three CHECKs make an unknown op kind impossible at rest.** A new kind needs a migration; one deployment is one server version, so the only reader that can meet an unknown kind is a client, and section 5 gives that case a rule.
- **`store/account_deletion.rs:104`'s existing `UPDATE canvas_ops SET author_id = NULL` becomes `SET actor_id = NULL`.** It must not be forgotten; without it a deleted account stays named as the person who wiped a canvas.
- **The rebuild is safe on a restored-from-Litestream deployment** for the same reason it is safe anywhere: the guard counts, and a non-zero count aborts the migration by name rather than dropping data.

**`canvas_objects` needs no new column.** `deleted_at` already exists, and `canvas_rtree_au` already fires `AFTER UPDATE OF ... deleted_at` and re-inserts only `WHERE NEW.deleted_at IS NULL`, so erase, clear **and restore** maintain the spatial index with no Rust involvement.
Restore working for free by symmetry is asserted today by nothing; section 9 fixes that.

`cargo sqlx prepare --workspace` after every statement below.

---

## 3. The routes

Three paths.
`http/canvas.rs` is 204 lines and `store/canvas.rs` is 419, so the new code goes in siblings: `http/canvas_ops.rs` and `store/canvas_ops.rs`.

```rust
Router::new()
    .route(
        "/channels/{channel_id}/canvas/objects",
        get(viewport).post(place),
    )
    .route(
        "/channels/{channel_id}/canvas/ops",
        get(list_ops).post(submit_op),
    )
    .layer(DefaultBodyLimit::max(MAX_BODY_BYTES))
```

The body limit stays on the router, not the route, so both paths inherit the 8 KiB byte-level refusal.
All four operations take `AuthedLimited<CANVAS>` (class 6, 60 burst, 10/s refill).

### 3.1 `GET /channels/{channelId}/canvas/objects` - unchanged wire

**No wire change.** `ViewportDto` already carries `latest_seq` and its doc already calls it "the channel's canvas high-water mark, to send back as `after_seq`".
The first slice shipped the field this design needs; it just was not authoritative.

What changes: `latest_canvas_seq` and `viewport_objects` move into **one deferred read transaction** (`self.pool.begin()`), so WAL gives both statements one snapshot and `latest_seq` means exactly "every op at or below this is reflected in what I just read".
That deletes the "read the cursor before the objects, over-reporting self-heals" reasoning at `http/canvas.rs:162-170` rather than restating it.

**The viewport SQL string itself is not edited.** `tests/it_canvas/canvas_index.rs:78-125` reads that literal out of the source, runs `EXPLAIN QUERY PLAN`, and asserts the first step's constraint suffix is exactly 12 characters.
Only the executor changes from `&self.pool` to `&mut *tx`.

The four `prev_*` parameters stay working and gain `deprecated: true` with a description saying the op cursor supersedes them.
Removing them is a non-additive schema change and no client sends them.

Gate: `VIEW_CHANNEL | USE_CANVAS`, one `permissions_in_channel` with a unioned `contains`.
No timeout check; it is a read.

### 3.2 `POST /channels/{channelId}/canvas/objects` (place) - one behaviour change

Unchanged except: it now writes a `place` op row and one `canvas_op_targets` row with the seq it already allocated, inside the transaction it already has.

And **`PlaceError` gains a `Removed` variant**, mapped to `409 "that object was removed"`, distinct from the existing `IdConflict` 409 for "that id belongs to another channel".
Today `fetch_object`'s `(true, true)` branch answers `IdConflict`, and the client explains every 409 as "This canvas is full, or that id is taken." That message becomes wrong for the common case the moment erase ships: an honest retry of a stroke a moderator erased in the ~750ms retry span.
Without this split, the first thing anybody notices about erase is nonsense copy and optimistic ink that will not go away.

Note the benign consequence of restore: a placement replayed *after* a restore finds a live row in the same channel and answers `fresh: false`.
Both answers describe the truth at the time they were given.

Timeout: **unchanged**, the existing explicit `timed_out_until` check stays.

### 3.3 `POST /channels/{channelId}/canvas/ops` - the mutation route

One route, one contract case, one discriminated body.
It is a POST rather than a `DELETE` on the object path because ops carry a client-minted id and a batch, and because idempotency then works identically to place.

Request:

```json
{"id": "0198f2c1-...", "kind": "remove", "object_ids": ["...", "..."]}
{"id": "0198f2c4-...", "kind": "clear", "before_seq": 5121}
{"id": "0198f2c9-...", "kind": "restore", "target_op": "0198f2c1-..."}
```

Response `201`:

```json
{"op": {"id": "...", "seq": 5122, "kind": "remove", "affected": 3, "created_at": 1}, "fresh": true}
```

A replay of a known op id returns the stored op with `"fresh": false` and publishes nothing, the `if placement.fresh` shape place already uses.

| Status | When |
|---|---|
| `201` | Written, or replayed. `affected` may be 0. |
| `400` | Unknown `kind`, malformed id, `object_ids` empty or over 64, `object_ids` present on clear/restore, `before_seq` missing or negative on clear, `target_op` missing on restore. |
| `401` | Not authenticated. |
| `403` | Missing `VIEW_CHANNEL`/`USE_CANVAS`; or removing another member's object without `MANAGE_CANVAS`; or clearing without `MANAGE_CANVAS`; or restoring an op you did not author without `MANAGE_CANVAS`. |
| `404` | `target_op` names an op that is not in this channel; or an `object_ids` entry is not in this channel. One answer for both absent and foreign, so the route is not a deployment-wide existence oracle. |
| `409` | A restore would push the channel past `MAX_OBJECTS_PER_CHANNEL`. |
| `429` | Over the canvas budget. |

**Gate, in this order**, one `permissions_in_channel` for all of it:

1. `contains(VIEW_CHANNEL | USE_CANVAS)` or 403.
2. `let may_moderate = permissions.contains(MANAGE_CANVAS);`
3. `remove`: fetch each object channel-scoped inside the write transaction; any not in this channel is 404; any whose `author_id != Some(caller)` without `may_moderate` is 403. `author_id` is NULL after account deletion, so an anonymised object is nobody's and only `MANAGE_CANVAS` removes it.
4. `clear`: `may_moderate` or 403.
5. `restore`: the target op's `actor_id == Some(caller)`, or `may_moderate`, or 403. **This is the gate the product judge named as the difference between moderating a canvas and animating it**: without it the person being moderated undoes the moderation, and every erase becomes a race the griefer wins because they are paying attention and the moderator is not.

**Timeout: no check on this route.** One sentence, and it is the rule: *a timeout freezes the pen, not the eraser.* Refusing erase to a timed-out member means a timeout's practical effect is to lock their defacement in place, which is backwards; it also follows message delete, which is left on authorship alone because "a delete publishes an id rather than words", and `VIEW_CHANNEL` is not in `TIMEOUT_DENY` so a timed-out member can already delete their own messages.
The abuse is bounded: place is still refused, and an object can only be removed once per restore.
`TIMEOUT_DENY` subtracts no management bit anywhere, so clear and moderator-restore are unaffected for the same reason every other moderation verb is.

**Transaction shape**, all inside `begin_write()` (`BEGIN IMMEDIATE`, so the read that decides the write is under the write lock):

1. `SELECT ... FROM canvas_ops WHERE id = ?`.
   Present and same channel: commit, return `fresh: false`.
   Present and other channel: 404.
2. Authorise per 3-5 above.
3. Apply:
   - `remove`: `UPDATE canvas_objects SET deleted_at = ? WHERE id = ? AND channel_id = ? AND deleted_at IS NULL`, one statement per id.
     `affected` is the sum.
   - `clear`: `UPDATE canvas_objects SET deleted_at = ? WHERE channel_id = ? AND deleted_at IS NULL AND seq <= ?`.
   - `restore`: `UPDATE canvas_objects SET deleted_at = NULL WHERE id = ? AND channel_id = ? AND deleted_at IS NOT NULL` for each object the target op named, after a `COUNT(*)` ceiling check in the same transaction.
4. **If `affected == 0`, commit and return with no seq allocated, no op row, no target rows, nothing published.** An op row exists only for a real state transition.
   That single rule keeps the stream free of no-ops, keeps every client's replay meaningful, and is what makes the density argument true.
5. Otherwise allocate the seq, insert the op and its target rows, commit, publish.

The per-id loop in step 3 is 64 point operations on a unique index.
`sqlx::query!` cannot bind a dynamic `IN` list without giving up the compile-time check and the offline cache, and `json_each` yields TEXT where `canvas_objects.id` is BLOB, which never matches and would silently drop the index.
It is the least elegant part of the server and it is bounded; section 11 records the cost.

### 3.4 `GET /channels/{channelId}/canvas/ops`

Query: `after_seq` (required, `>= 0`), `limit` (optional, default 100, clamped 1..200).

```json
{
  "ops": [
    {"seq": 41, "id": "...", "kind": "place", "actor_id": "...", "created_at": 1,
     "object": { /* CanvasObject */ }},
    {"seq": 42, "id": "...", "kind": "remove", "actor_id": "...", "created_at": 2,
     "object_ids": ["...", "..."]},
    {"seq": 43, "id": "...", "kind": "clear", "actor_id": "...", "created_at": 3,
     "before_seq": 40},
    {"seq": 44, "id": "...", "kind": "restore", "actor_id": "...", "created_at": 4,
     "target_op": "...", "object_ids": ["..."]}
  ],
  "latest_seq": 44,
  "has_more": false,
  "reset": false
}
```

- `object` is present on a `place` **only when the object is still live**, via `LEFT JOIN canvas_objects o ON ... AND o.deleted_at IS NULL`.
  Absent means "already gone at snapshot time, do not paint it".
  That is correct rather than a shortcut, because the client always pages to the head before considering itself caught up.
- **The page and its `latest_seq` are read in one deferred read transaction**, same as the viewport read.
- `reset: true` always comes with `ops: []` and means discard the document and cold-fetch.
  Returned when any of:
  - `latest_seq - after_seq > CANVAS_OP_GAP`;
  - `after_seq` is below the retained floor (`MIN(seq)` for the channel).
    No sweep exists yet, so this cannot fire today; it ships now so a sweep can be added later with no wire change;
  - **`after_seq > latest_seq`**, which happens after a Litestream restore.
    Without this branch the client stalls silently forever.
    Only D1 caught this.
- **The floor is re-evaluated on every page, not only the first.**
- `has_more` is over-read by one and dropped from the **back** (the opposite end from the viewport read, which reads newest-first and reverses).
- **The page also stops early on a byte budget**, `CANVAS_OP_PAGE_BYTES`.
  A `place` op carries whole props at up to 4 KiB, so a row count alone does not bound the response.
  Same reasoning `splitStroke` uses for a stroke.

Gate: `VIEW_CHANNEL | USE_CANVAS`, byte-identical to the viewport read.
No timeout check.

**The OpenAPI description must state that this cursor is stable and paging is correct**, in those words, because the sibling viewport operation's description says the opposite about its own `has_more` and somebody will copy it.

### 3.5 Contract work each route implies

- **`schema/openapi.yaml`**: one new path with two operations; a `delete` on nothing (there is no DELETE); schemas `CanvasOp`, `CanvasOpRequest`, `CanvasOpResult`, `CanvasOpPage`; three new WS event schemas plus their `$ref`s in the `oneOf` at `:4073`; the `deprecated: true` on the four `prev_*` parameters; and the rewritten `latest_seq` description.
  The canvas block is `:2145-2296`, schemas at `:3478-3580`, the WS event at `:4077-4096`.
- **`tests/it_infra/response_contract/script/content.rs`**: two cases, `submitCanvasOp` and `listCanvasOps`, beside `placeCanvasObject` (`:93`) and `listCanvasViewport` (`:108`).
  **Order matters:** place a *second* object first, so `listCanvasViewport`'s existing non-empty-page reasoning survives the erase; then `listCanvasOps`; then `submitCanvasOp` with a `remove`.
- **`http/capability.rs`** needs nothing.
  The list is derived from the router by probing with `SLIMMPROBE` and reading the `Allow` header, so a new path appears on its own.
  `Version.capabilities` reaches the client, so a client talking to an older server hides the eraser rather than showing a control that 405s.

---

## 4. The events

Three variants in `hub.rs`.
All carry ids and counts, never content.

```rust
/// Objects were removed from a channel's canvas.
///
/// Ids only, the shape [`Event::MessageDeleted`] already uses: a removal
/// publishes an id rather than content. The actor is deliberately absent, so a
/// moderation act does not name its moderator to the whole channel.
CanvasObjectsRemoved { channel_id: ChannelId, seq: Seq, op_id: CanvasOpId,
                       object_ids: Vec<CanvasObjectId> },

/// Every object placed at or below `before_seq` went at once.
///
/// Carries no ids: a clear can cover the channel's whole live ceiling, and
/// [`CHANNEL_CAPACITY`] buffers 1024 cloned events, so a 20,000-id frame is
/// exactly what the props ceiling exists to stop one object doing. A receiver
/// drops what it holds below the bound and keeps the rest.
CanvasCleared { channel_id: ChannelId, seq: Seq, op_id: CanvasOpId,
                before_seq: Seq },

/// A removal was undone. Ids only; a receiver that cannot resurrect them
/// locally refetches.
CanvasObjectsRestored { channel_id: ChannelId, seq: Seq, op_id: CanvasOpId,
                        object_ids: Vec<CanvasObjectId> },
```

Frames in `ws/frames.rs`: `"canvas.objects.removed"`, `"canvas.cleared"`, `"canvas.objects.restored"`.

`object_ids` is bounded at `MAX_REMOVE_IDS_PER_OP` (64), which is what keeps both the 4 KiB frame ceiling and the 1024-slot ring honest.
Section 8 shows the arithmetic.

### Authorization per receiving connection

All three are **tier 4** (channel-scoped through `PermissionCache`), identical to `CanvasObjectPlaced`.
Putting any of them in the tier-2 deployment-wide block at `ws.rs:226-250` would ship them with no permission check at all.

Three edits in `ws.rs`:

1. Channel extraction (`:263-284`) gains three arms returning `*channel_id`.
2. **The second-bit gate at `:308-313` is replaced, not widened.** Today it is `matches!(event, Event::CanvasObjectPlaced { .. })`, which names one variant; a removal event added without editing it ships gated on `VIEW_CHANNEL` alone and leaks removals to a member an overwrite shut out.
   Widening the `matches!` fixes today and leaves the same trap for the next variant.
   Instead:

```rust
/// The bit a frame needs beyond `VIEW_CHANNEL`, if any. Exhaustive with no
/// wildcard, so a new variant does not compile until somebody classifies it.
fn extra_bit(event: &Event) -> Option<Permissions>
```

   This is the same discipline `moves_permissions` already uses, and it is the one structural improvement to the socket in this slice.
3. Frame construction (`:434-438`) gains three arms.

**`moves_permissions` (`hub.rs:229-252`): all three go in the `false` arm.** It is an exhaustive match with no wildcard, so this will not compile until it is done.
Neither the epoch nor the `PermissionCache` needs any other change: `MANAGE_CANVAS` and `USE_CANVAS` both come out of the same cached `Permissions` set at no extra cost, which is precisely the reason `permission_cache.rs:10-19` gives for caching a set rather than a bit.

None of the three is gated on `MANAGE_CANVAS`.
The gate is on the ability to *see* the canvas, not on the ability to have performed the act, exactly as `MessageDeleted` reaches everybody who could see the message.

Client side: `events.dart:137-148` gains three cases, `events_frames.dart` gains three classes, and **`client/packages/api/lib/api.dart`'s explicit `show` list gains all three class names**.
That list is the recorded trap.
The new HTTP methods go on the existing `SlimmApiCanvas` extension, which is already named there.

---

## 5. Offline reconciliation

### The asymmetry this rests on

The canvas has **no durable local state**: `grep -rin canvas client/packages/data/lib` is empty.
`CanvasDocument` lives in the mounted `_CanvasPaneState` and dies with it.
So "the pane was closed" and "the client was offline" are the same state, and the recovery for both is a cold viewport read, which by construction contains no removed object.

That makes a reset *cheap* here in a way it is not for messages, and it is why the gap threshold can be small and why local persistence is a deliberate non-goal.

### Case A: the pane was closed

Nothing to reconcile.
Opening it is one cold read of the current projection; the read's `latest_seq` becomes `_asOfSeq`.
No mechanism, no code.

### Case B: the pane stayed open across a drop

The pane holds `int _asOfSeq` and a `Set<String> _removedIds`.

**Cursor rules, and each one is load-bearing:**

- `_asOfSeq` is set from a cold fetch's `latest_seq`, and only when that fetch follows a document reset.
- It advances by consuming the ops feed, or by applying a live frame whose `seq == _asOfSeq + 1`.
- **It never advances from a region refetch's `latest_seq`.** This is the subtlest thing in the design.
  An erase at seq 50 in region 1, then a pan to region 2 fetching at `latest_seq` 60, would otherwise leave the client holding an object it has been told to drop with its cursor already past the op that says so, forever.
  A region refetch applies its objects (idempotent by id, filtered by `_removedIds`) and then runs `catchUp()` from the *existing* cursor.

**Live frames:**

- `seq <= _asOfSeq`: ignore, already materialised.
- `seq == _asOfSeq + 1`: apply, advance.
  **This is only sound because the sequence is dense over ops**, which is the whole point of the op stream.
- `seq > _asOfSeq + 1`: a gap.
  Run `catchUp()`.
  This closes the one documented silent failure in the fan-out path: `ws.rs:300-302` fails closed on a store blip for one event on one connection **without closing the socket**, so nothing else would ever notice.
  It also closes the subscribe-versus-fetch race on pane open.

**Catch-up:**

```
catchUp():
  for page in 0 .. MAX_CATCHUP_PAGES:
    answer = GET /canvas/ops?after_seq=_asOfSeq&limit=100
    if answer.reset or answer.latestSeq < _asOfSeq:
      hardReset(); return
    for op in answer.ops:            // ascending seq, server order
      apply(op)
      _asOfSeq = op.seq
    if not answer.hasMore:
      _asOfSeq = max(_asOfSeq, answer.latestSeq)   // sound: one snapshot
      document.refresh()                            // once, not per op
      return
  hardReset()
```

`apply`:

- `place` with an object: `applyPlaced`, refused if the id is in `_removedIds`.
- `place` with no object: skip, and add the id to `_removedIds`.
- `remove`: `document.removeObject(id)` for each, and add each to `_removedIds`.
- `clear`: `document.clearBelow(op.beforeSeq)`.
- `restore`: drop each id from `_removedIds`, then set `_fetched = null` so the next camera move refetches the region.
  A local resurrect is not attempted: the stroke's payload was freed on removal (section 6), and re-materialising it is exactly what a refetch does.
- **Any kind the client does not know: `hardReset()`, never "skip".** Skipping an unknown op could mean leaving ink on screen the server has removed, which is the one failure this slice exists to prevent.

`hardReset()`: empty the document, clear `_fetched`, clear `_removedIds`, cold-fetch, adopt `latest_seq`.
**Rate-limited to one per five seconds**, or a server emitting an unknown kind in a stream turns every stale client into a refetch loop.

**A 429 during catch-up is retried with backoff, never treated as a reset.** A large gap after a server restart is N clients times up to 25 pages against a 60-burst bucket; a client that maps 429 onto `hardReset` turns rate limiting into a refetch storm.

`catchUp()` runs on: the first successful viewport read (closing the window between the snapshot and the socket being useful), and on every transition of `syncControllerProvider` into `SyncStatus.live`.
**There is no periodic poll.** D2 needed one because a dropped frame silently advanced its cursor; density plus the `+1` gap detector makes the next frame the detector.

### Truncation

A truncated ops page is not special: `has_more` is true, the loop pages again from `op.seq`, and the cursor is correct at every page boundary because every op has its own seq value and there are no ties.
Past `MAX_CATCHUP_PAGES` the client resets, which costs one viewport read.

A truncated **viewport** page is unchanged from slice one: `_fetched` is not recorded (`page.hasMore ? null : region`), because recording it would let the next pan skip a region the read never returned.

### The in-flight-page resurrection, and why `_removedIds` exists

A viewport read in flight at snapshot seq 100 carries object X. X is erased at 101. The removal frame arrives first, catch-up runs, `_asOfSeq` reaches 101, and `document.removeObject(X)` is a no-op because the document never held X. The fetch response then lands and `applyPlaced(X)` resurrects it permanently, with no later catch-up re-delivering the erase.

`_removedIds` is what makes that impossible, and it is why `applyPlaced` consults it rather than relying on a dead `_slotById` slot.
It is capped at `MAX_OBJECTS_PER_CHANNEL` with FIFO eviction, because no viewport read in flight can carry more ids than the channel's live ceiling.

### What this does not close

A client learns about placements *and* removals while its pane is open.
It still does not learn about placements outside its fetched regions, because the feed is a catch-up channel for a pane, not a subscription to a whole canvas.
Panning there fetches them.
Stated so nobody looks for the mechanism.

---

## 6. Client changes, file by file

### `client/packages/voice_canvas/lib/src/spatial_grid.dart`

**New `remove(int slot)`, `reset()`, `liveLength`.**

```dart
/// Takes a slot out of every bucket it spans and parks its box inverted, so
/// both cull branches reject it on the first comparison of the overlap test
/// they already run. Slots are never renumbered: `CanvasDocument` addresses
/// its strokes by the integer this class hands out, and compaction would
/// mis-address every stroke above the hole.
void remove(int slot) {
  final base = slot << 2;
  final left = _bounds[base];
  final right = _bounds[base + 2];
  // The parked box is inverted, so this is also the idempotence guard.
  if (right < left) return;
  ...
  _bounds[base] = double.infinity;
  _bounds[base + 1] = double.infinity;
  _bounds[base + 2] = double.negativeInfinity;
  _bounds[base + 3] = double.negativeInfinity;
  _removed++;
}
```

**Infinities, not NaN.** Verified against `spatial_grid.dart:118-125` and `:145-152`: the test is a *rejection* test, `if (_bounds[base] > right || ...) continue;`, so all-comparisons-false means **kept**.
A NaN-parked slot would be emitted into `out.slots` on every frame from every viewport, forever, and D1's design asserted the opposite.

**Bucket removal is swap-remove**, `bucket[i] = bucket.last; bucket.removeLast();`, not `List.remove`.
Order is irrelevant because `CanvasDocument.paintOrder` sorts by `z_index`, which is exactly why that sort exists.
`List.remove` is a linear scan preserving an order nothing reads, and in the spike's clustered worst case a single bucket holds thousands of slots.

**`query`'s adaptive threshold keeps comparing against `_count`, not `liveLength`.** It is choosing between "probe this many cells" and "test this many slots", and the linear branch still walks parked slots, so `_count` is the honest cost of that branch.
Parked slots make the grid branch strictly cheaper and the linear branch no cheaper.
D1 had this backwards.

`_stamp` is left alone: a parked slot is out of every bucket so `queryGrid` never reaches it, and `queryLinear` rejects it by bounds.

**Breaks if not done:** `spatial_grid_test.dart:8`'s "grid and linear scan agree on random worlds" is the test that catches a wrong park, and it only catches it if the new tests in section 9 remove things first.

### `client/packages/voice_canvas/lib/src/canvas_scene.dart`

`remove(int slot)` and `reset()` delegate to the grid (`_grid` is private, so removal has to be published through the scene too).
`objectCount` becomes `_grid.liveLength`, which finally makes it agree with `CanvasDocument.objectCount` instead of diverging the moment anything dies.

### `client/packages/voice_canvas/lib/src/canvas_document.dart`

- `_strokes` becomes `List<CanvasStroke?>`, so removal writes `null` and drops the `Path` and the points.
  Paths dominate this package's footprint; nulling is the single largest memory win available.
- `removeObject(String id)`: mark removed, `scene.remove(slot)`, `_strokes[slot] = null`, decrement `objectCount`, keep the `_slotById` entry so a duplicate is a no-op.
- `restoreLocally(String id)` does **not** exist.
  Restore drops the tombstone and refetches; the payload is gone.
- `clearBelow(int beforeSeq)`: removes every stroke with `0 < seq <= beforeSeq`.
  The `0 <` guard is what spares locally drawn strokes, which carry `seq: 0` until confirmed.
- `applyPlaced` gains one line at the top and returns `int?`: `if (_removedIds.contains(input.id)) return null;`.
  Its known-id branch also refuses to resurrect a dead slot; today it silently leaves the stroke invisible while `objectCount` has already been decremented, which is a latent oddity this fixes.
- `paintOrder` becomes null-aware: `where((s) => _strokes[s]?.alive ?? false)`.
- `CanvasStroke` gains `points` as a **`Float32List`** in world coordinates, for hit testing.
  `List<double>` is boxed at roughly 16 bytes each, so a 250-point segment is ~8 KB against `Float32List`'s ~2 KB, a 4x difference at the 20,000 ceiling.
- `kill(id)` stays exactly as it is and keeps its name.
  It means "this commit never landed", a different thing from "this was removed", and it is still the only thing `onFailed` should do.
  The two must not be merged.

**Breaks if not done:** `canvas_document_test.dart:43-56` ("a killed stroke leaves the paint order") pins the current shape and gets a sibling rather than a rewrite.

### `client/packages/voice_canvas/lib/src/canvas_hit_test.dart` (new)

Nearest-segment-within-tolerance over a stroke's `points`, culled to a small rect around the pointer, alive only, sorted by `z_index` descending, first within `width / 2 + slop`.
A bounding-box test over-erases neighbours that a long diagonal stroke's box happens to cross.

### `client/packages/voice_canvas/lib/src/canvas_surface.dart`

Gains a `tool` (`pen` or `eraser`) and an `onErase(Offset world)` callback.
**`enabled` finally gets a real value** - it is declared, documented as the timed-out member's read-only state, and never passed by `CanvasPane` today.

### `client/packages/app/lib/src/screens/canvas/`

`canvas_pane.dart` is already 314 lines, past the 300 review budget, so this splits:

- **`canvas_sync.dart` (new)**: `_asOfSeq`, `_removedIds`, `catchUp()`, `hardReset()` with its five-second floor, the live-frame gap rule, the `syncControllerProvider` listener.
- **`canvas_ops_controller.dart` (new)**: op minting, the undo ledger, the erase-on-confirm flag.
- **`canvas_pane.dart`**: `_onEvent` gains three cases; `_apply` unchanged; `_fetch` applies its page and then calls `catchUp()` from the existing cursor.

**The `_lastCameraView` guard must survive all of this.** Every path above ends in `refresh()`, which is a content-only notification, and the guard at `:125-127` is what stops those rescheduling a fetch forever.
`canvas_pane_test.dart:270-298` is the regression test and it gets extended, not replaced.

**A clear needs no refetch.** `clearBelow` runs in place and `_fetched` stays valid: the region is still covered, and now covered and empty.
That is the one axis where D1 beat D2, and it is worth up to 2,000 `Path` reconstructions at the exact moment a moderator is watching the screen.

### `canvas_commit_queue.dart`

- `_explain` gains wording for the new distinct 409: "That stroke was erased while it was being saved", and the queue calls `document.removeObject(id)` rather than leaving optimistic ink on screen.
- **Erase-on-confirm.** Undoing a gesture whose commit is still in flight must not issue the remove first, or it 404s and the ink survives on the server while being gone from the drawer's screen.
  An undo of a pending id sets a flag; `onPlaced` for such an id issues the op immediately.
  Placements still unsent are cancelled from `_pending` outright, no round trip.
- `CanvasCommit` gains **no** verb and the queue stays placement-only.
  Its library doc's "ordering is what `z_index` is seeded from" argument is exactly what a second verb on the same queue would muddle; ops go out on their own path, ordered by the server.
- `CommitOutcome` at `:14` is declared and referenced nowhere in the repo.
  Delete it.

### `canvas_bar.dart`

Pen/eraser toggle (two tools is a toggle, not a dock), an Undo button **and** `Ctrl+Z` (a keyboard-only affordance is invisible to `canvas_pane_test.dart:303-332`'s reachability guard and to a touch device), and an overflow "Clear canvas" behind an `AppDialog` confirm naming the object count.

### `client/packages/api/lib/`

`client_canvas.dart` gains `submitCanvasOp` and `canvasOps`; `models_canvas.dart` gains `CanvasOp` and `CanvasOpPage`; `events.dart` and `events_frames.dart` gain three each; **`api.dart`'s `show` list gains every new type name.**

### Undo, stated

Undo is an ordinary `remove` op naming exactly the ids `splitStroke` minted for that gesture - the gesture-to-ids ledger that does not exist today.
One op, one seq, one event, so a client dying mid-undo cannot leave a half-erased gesture and other viewers do not watch a long stroke dissolve piecewise.

Undo of an **erase** is a `restore` naming that op's id, which is why restore is a server verb rather than a client re-place.
Undo of a **clear** is the same restore, which is what makes clear a moderation action rather than a demolition somebody is afraid to press.

Stack depth 32, in memory, per pane.
It does not survive closing the pane, and the UI says so rather than letting Ctrl+Z silently stop working.

---

## 7. The permission model

**On a fresh self-host, `@everyone` holds `USE_CANVAS` and not `MANAGE_CANVAS`.** `EVERYONE_DEFAULTS` is unchanged; `USE_CANVAS` has been in it since the constant was first written, so there is no cohort of deployments missing it.

So, out of the box and with no operator action:

- Any member can draw, erase **their own** ink (individually or by undoing a gesture), and restore their own erases.
- An administrator holds `MANAGE_CANVAS` through `Permissions::ALL`, so they can erase anything, clear, and restore anybody's removal.
  **That is the hazard closed**: today nobody at all, including the owner, can clean up a defaced canvas.

**To let a non-administrator moderate the canvas**, an operator ticks "Manage the voice canvas" in the role editor, or grants it as a channel overwrite.
Both already render the bit today; this slice is the first time ticking it does anything.
No migration, no default-grant change, no client permission edit.

**`MANAGE_CANVAS` is enforced, not added.** Bit 14 exists at `permissions.rs:64`, is in `ALL` at `:84` (so `roles.rs:297` and `overwrites.rs:113` already accept it), is mirrored at `permissions.dart:25` and labelled at `:44`.

**`USE_CANVAS` does not split.** Section 1.

**DMs need nothing.** `DM_BASE` holds no canvas bit and `permissions_in_channel` returns from the DM branch before the evaluator, so all four operations 403 inside a DM for free.

**No escalation guard.** Section 1; residual in section 11.

**One missing test this slice must add:** nothing anywhere asserts that `Permissions::ALL` is the union of every named constant.
A bit omitted from `ALL` is a bit administrators do not hold, that the API refuses to grant, and that no test catches.
That test protects exactly the enforcement being added here.

**The client's permission read is deployment-wide.** `MANAGE_CANVAS` comes from `GET /me`, which does not know about channel overwrites, so the clear control can appear to somebody an overwrite denies and 403 on use.
That is the compromise channel management already makes (`manage_channel_sheet.dart`), so it is consistent rather than novel.
It is still a control that lies; residual in section 11.

---

## 8. Ceilings

| Name | Value | Reasoning |
|---|---|---|
| `MAX_REMOVE_IDS_PER_OP` | **64** | The event frame must fit `MAX_FRAME_BYTES` (4 KiB). 64 uuid strings at 39 bytes each with separators is ~2.5 KiB, leaving room for the envelope, and the same bound caps the write-lock statement count at 64 indexed point updates per request. At the Canvas class's 10/s that is ~640 statements/second of write-locked work in the worst case. It is also comfortably above any real gesture: `splitStroke` at a 3500-byte budget produces single-digit segments for a normal stroke. |
| `CANVAS_OPS_PAGE` | default **100**, max **200** | A `place` op carries whole props at up to `MAX_PROPS_BYTES` (4 KiB), so 200 bounds one response at 800 KiB, an order of magnitude under the viewport read's worst case of 2000 x 4 KiB. |
| `CANVAS_OP_PAGE_BYTES` | **512 KiB** | The row count alone does not bound the response because op payloads vary by 3 orders of magnitude. Stop the page early once accumulated props bytes cross this, the same reasoning `splitStroke` uses for a stroke and the reason a "256-point stroke" cannot be split by point count. |
| `CANVAS_OP_GAP` | **2,000** | Set equal to the viewport read's own `MAX_LIMIT`. Past that many ops behind, replaying is no cheaper than re-reading, and the re-read is strictly better because it also drops everything outside the viewport. |
| `MAX_CATCHUP_PAGES` (client) | **25** | 25 x 100 = 2,500, just past `CANVAS_OP_GAP`, so any backlog the server is willing to serve fits inside it and anything larger is churn worth abandoning for a reset. |
| `hardReset` floor (client) | **one per 5s** | Without it, a server emitting an op kind an older client does not know turns every stale client into a refetch loop. Five seconds matches `PermissionCache`'s TTL, which is the other place this codebase decided what "recently enough" means. |
| `_removedIds` (client) | **20,000, FIFO** | `MAX_OBJECTS_PER_CHANNEL`. No viewport read in flight can carry more ids than the channel's live ceiling, so an id evicted past that cannot be re-delivered by an outstanding read. |
| Undo ledger | **32 gestures** | About the product, not the memory. A deeper stack that dies on pane close is a promise the UI cannot keep. |
| Clear / restore transaction | bounded by **`MAX_OBJECTS_PER_CHANNEL`** (20,000) | Not a new bound. The existing live ceiling is what caps the bulk `UPDATE` at 20,000 row rewrites and 20,000 R-Tree trigger firings. Named because it is the largest single write this deployment can be asked to do; a restore of a full clear is the slowest, and it happens at exactly the moment somebody is anxiously waiting for their canvas back. |
| `canvas_ops` rows | **unbounded** | Deliberate. Section 1: the same growth class `messages` has had since Phase 1, at the same rate limit, with the same absence of a sweep. A ceiling whose only remedy is deleting the channel is worse than no ceiling. |

Unchanged: `MAX_PROPS_BYTES` 4 KiB, `MAX_OBJECT_EXTENT` 8192, `MAX_OBJECTS_PER_CHANNEL` 20,000 live, `MAX_BODY_BYTES` 8 KiB, `WORLD_LIMIT`, the Canvas rate class.

---

## 9. The tests that must exist

Each is stated as the property it binds and the mutation that must fail it.
A test that cannot fail is worse than no test.

### Server

| Property | Mutation that must fail it |
|---|---|
| The canvas sequence is dense over ops: after N mixed mutations, the ops feed from 0 returns exactly N rows with consecutive seqs. | Allocate a seq on the `affected == 0` branch. |
| An op with `affected == 0` writes no op row and publishes nothing. | Move the seq allocation above the `rows_affected` check. |
| A replayed op id returns the stored op with `fresh: false` and publishes nothing. | Drop the `canvas_ops WHERE id = ?` lookup. |
| A member cannot remove another member's object; the same call with `MANAGE_CANVAS` succeeds. | Drop the `may_moderate` branch. |
| A member cannot restore an op they did not author; a moderator can. | Drop the restore authorship check. **This is the gate that stops moderation being undone by its subject.** |
| A timed-out member is refused a placement, allowed a removal of their own object, and still holds `USE_CANVAS` afterwards. | Add a `timed_out_until` check to the ops route, or remove it from place. Mirrors `canvas_write.rs:184-224`. |
| A clear does not touch objects whose placement seq exceeds `before_seq`. | Drop the `AND seq <= ?` predicate. |
| A restore is refused with 409 when it would exceed `MAX_OBJECTS_PER_CHANNEL`, inside the same transaction that counts. | Move the count outside the transaction. |
| The R-Tree entry leaves on erase and comes back on restore. | Remove `deleted_at` from `canvas_rtree_au`'s `UPDATE OF` column list. This is the first test of the un-delete symmetry, which works today and is asserted by nothing. |
| The ops feed's `place` row carries no object once that object is dead. | Drop `AND o.deleted_at IS NULL` from the LEFT JOIN. |
| The feed answers `reset` on all three triggers, including `after_seq > latest_seq`. | Remove any one branch. |
| The feed's page and its `latest_seq` share one snapshot: a concurrent write between them cannot produce a `latest_seq` the page does not cover. | Split them into two pool calls. |
| A member denied `USE_CANVAS` by an overwrite receives none of the three new frames. | Revert `extra_bit` to a `matches!` naming only `CanvasObjectPlaced`. Extend `canvas_live.rs:141-181`. |
| An idle text-only connection survives a 60-op burst. | Existing shape in `canvas_live.rs:228-260`. |
| A placement replayed after its object was erased answers the distinct `Removed` 409, not `IdConflict`. | Merge the two variants. |
| `Permissions::ALL` is the union of every declared constant. | Remove any bit from `ALL`. |
| The migration aborts by name when `canvas_ops` is non-empty. | Delete the guard table. |
| Account deletion nulls `canvas_ops.actor_id`. | Leave the column name at `author_id` in `account_deletion.rs`. |
| `openapi_contract` and `response_contract` cases for both operations. | Add the route without the schema entry. |

### Client

| Property | Mutation that must fail it |
|---|---|
| Grid and linear culls agree on random worlds **after removals**. | Park with NaN instead of inverted infinities. This is the test that catches the single worst error in the field. |
| `remove` is idempotent and leaves paint order and `objectCount` correct. | Drop the `right < left` guard. |
| A removed slot is emitted by neither cull branch, at any zoom, on either side of the adaptive threshold. | Skip the bucket removal, or skip the bounds park. |
| The adaptive threshold still compares against `_count`. | Change it to `liveLength`. |
| `clearBelow` spares strokes with `seq == 0`. | Drop the `0 <` guard; locally drawn ink vanishes as it is drawn. |
| A clear does not drop `_fetched` and issues no refetch. | Replace `clearBelow` with a reset-and-refetch. |
| An object delivered by a viewport page is refused when its id is in `_removedIds`. | Remove the `_removedIds` check from `applyPlaced`. **This is the in-flight resurrection the protocol judge named.** |
| A region refetch does not advance `_asOfSeq`; a removal outside the refetched region is still applied by the following catch-up. | Set `_asOfSeq = page.latestSeq` in `_fetch`. Needs a **two-region** test; no single-region test can see it. |
| A live frame with `seq > _asOfSeq + 1` triggers exactly one catch-up. | Apply the frame and advance unconditionally. |
| A live frame with `seq <= _asOfSeq` is ignored. | Apply it. |
| An unknown op kind resets, and resets no more than once per five seconds. | Skip unknown kinds. |
| Catch-up applies place, remove, clear and restore in seq order and is idempotent when replayed from a stale cursor. | Reverse the page order. |
| A 429 during catch-up retries and does not reset. | Map 429 onto `hardReset`. |
| Exactly one ops catch-up per reconnect. | Register the listener in `build`. Mirrors `canvas_pane_test.dart:251-264`. |
| Undo of a gesture issues **one** op naming exactly that gesture's ids. | Issue one op per segment. |
| Undo of a still-unsent gesture cancels the placements and issues no op; undo of an in-flight one erases on confirm. | Issue the op immediately. |
| The eraser collects no foreign ink when `manageCanvas` is false. | Drop the filter. |
| `canvas_pane_test.dart:270-298`'s no-unbounded-refetch guard still passes with catch-up in place. | The likeliest thing this slice breaks. |
| `canvas_pane_test.dart:303-332`'s reachability guard still passes with the tool toggle in place. | Move the eraser behind a keyboard-only affordance. |
| `canvas_scene_test.dart:11-27`'s "a viewport change repaints without rebuilding any widget" (`stats.builds == 0`). | Route any removal path through Riverpod inside the render loop. |

---

## 10. Ordered PR breakdown

**PR 1 - the op stream, server only, no removal verbs.**
Migration 0026, `store/canvas_ops.rs`, `place` writes its op row, `GET /channels/{id}/canvas/ops`, the viewport read moved into one read transaction, openapi and response-contract entries, `.sqlx`.
*Reviewable against:* place still works unchanged over the wire; the feed returns a dense consecutive sequence of `place` ops; `reset` fires on all three triggers; the migration guard aborts on a non-empty table; `canvas_index.rs`'s plan assertion is still green.
No client change, no event, no permission change.
This is the whole spine and it is the PR to get right.

**PR 2 - remove and clear.**
`POST /channels/{id}/canvas/ops` with the `remove` and `clear` kinds, `MANAGE_CANVAS` enforcement, the two events, `extra_bit` replacing the `matches!`, `moves_permissions`, `PlaceError::Removed`, the `Permissions::ALL` union test.
*Reviewable against:* section 9's server table, minus the restore rows.
The socket gate is the highest-risk line in it.

**PR 3 - restore.**
The `restore` kind, its authorship gate, the ceiling check, the third event, the R-Tree symmetry test.
*Reviewable against:* a member cannot restore a moderator's removal; a restore past the object ceiling is a 409; the index entry comes back.
Deliberately last of the server three, because it is the only one whose absence leaves the product merely incomplete rather than incorrect.

**PR 4 - `voice_canvas` package only.
Can go fully in parallel with PRs 1 to 3.**
`UniformGrid.remove`/`reset`/`liveLength`, `CanvasScene` delegation, `CanvasDocument.removeObject`/`clearBelow`/`_removedIds`/`Float32List` points, `canvas_hit_test.dart`, `CanvasSurface` tool and `enabled`.
*Reviewable against:* section 9's first eight client rows.
It depends on no wire type and no API method, which is exactly why it can start on day one.
It ships behind no UI, so it is safe to land ahead of the server.

**PR 5 - api package plus reconciliation.
Needs PR 2 merged.**
`SlimmApiCanvas` methods, models, three events, the `show` list; `canvas_sync.dart`, the cursor rules, catch-up, live-frame handling, the `syncControllerProvider` listener.
*Reviewable against:* the two-region cursor test, the gap detector, the 429 rule, the unknown-kind reset, and both existing `canvas_pane_test` guards still green.
Still no user-visible affordance.
That is deliberate: reconciliation lands and is tested before anything can invoke it.

**PR 6 - the UI.
Needs PRs 3, 4 and 5.**
Eraser toggle, undo ledger and `Ctrl+Z`, erase-on-confirm in the commit queue, the clear control and its confirm, the `MANAGE_CANVAS` read, `_explain` wording, deleting `CommitOutcome`.
*Reviewable against:* the eraser collects no foreign ink without the bit; undo is one op; the reachability guard passes; the tool toggle is reachable by touch.

**Parallelism:** PR 4 runs alongside 1-3 from the start.
PRs 2 and 3 are strictly sequential on 1 and on each other (3 restores what 2 removes).
PR 5 needs 2 for the wire types and can be written against 2's openapi entry before 3 lands.
PR 6 is last.

Each PR title carries a conventional-commit prefix, because release-please reads only the squash title and a title without one silently omits the whole PR from the changelog.

---

## 11. Residuals

Named rather than hidden.
Each is a real cost this design accepts.

1. **`canvas_ops` and dead `canvas_objects` rows grow without a sweep.** A member can place-and-erase at 10/s indefinitely.
   This is the same growth class `messages` has had since Phase 1 at the same rate limit, and the alternative ceiling's only remedy was deleting the channel.
   A sweep is designed-for (the feed's floor branch exists and the reset path handles it) and not built, and its hard constraint is written down: hard-deleting a dead object row frees its id, and the id guard is what stops a replayed placement resurrecting an erased stroke.
2. **`MANAGE_CANVAS` with no escalation guard is enough to erase an administrator's work**, one op at a time, and to clear their canvas.
   Consistent with `MANAGE_MESSAGES`, which already lets a junior moderator delete an administrator's message.
   Mitigated by restore existing and by the trail never being compacted; not closed.
3. **The removal trail is written and has no reader.** `canvas_ops.actor_id` and `created_at` are durable, anonymised on account deletion, and surfaced in no UI and no route.
   That is the `is_encrypted` dead-weight shape this codebase already calls out.
   It is written now because adding the column later is a migration on a table that by then holds data, and because "who wiped this" is the first thing an operator asks and is answerable from SQL the day this lands.
4. **Nothing tells a member their ink was erased.** The frames carry ids only, matching `MessageDeleted`, so ink vanishes silently.
   To the person who drew it, moderation reads as a rendering bug.
5. **The clear and eraser controls are gated on a deployment-wide `MANAGE_CANVAS` read from `/me`.** In a channel where an overwrite denies it, the control appears and 403s.
   Consistent with `manage_channel_sheet.dart`; still a control that lies.
6. **Undo does not survive closing the pane**, and the ledger is per-pane and in memory.
   The UI says so; users will still expect otherwise.
7. **Retaining stroke points multiplies pane memory**, on top of growth that was already unbounded: `CanvasPane` evicts nothing on pan, so every cold fetch adds to `_strokes` and nothing removes a live one.
   `Float32List` makes it 4x cheaper than the obvious `List<double>`.
   Viewport-based eviction is the real answer and is not in this slice.
8. **`_bounds` and `_stamp` never shrink**, because slots are dense indices into three structures at once and compaction would mis-address every stroke above the hole.
   Roughly 6.6 MB of typed array after 200,000 removals in one pane session, reclaimed only by pane disposal.
9. **A restore of a full clear fires the R-Tree trigger 20,000 times** while holding the single writer, and it happens at exactly the moment somebody is anxiously waiting for their canvas back.
   Unmeasured.
   A timing assertion belongs in the test suite; if it exceeds budget, chunking breaks the one-op atomicity the whole design rests on, so the honest fallback is a faster disk.
10. **A batched remove is up to 64 sequential point updates inside one `BEGIN IMMEDIATE`.** `sqlx::query!` cannot bind a dynamic `IN` list without losing the compile-time check and the offline cache, and `json_each` yields TEXT where the id column is BLOB, so it would never match and would silently drop the index.
    Bounded, and the least elegant part of the server.
11. **`canvas_ops.seq` and `canvas_objects.seq` for a place are asserted equal by the writing code and by nothing else.** No FK, no CHECK.
    That is the seam where a second ordering authority could grow back; the density test in section 9 is the closest thing guarding it.
12. **The client's cursor rules are conventions the type system does not enforce.** Nothing prevents a future contributor writing `_asOfSeq = page.latestSeq` in `_fetch`, and only the two-region test fails when they do.
    A doc comment on the field names the rule and the reason; that is not a guarantee.
13. **The eraser is one tap per collection.** A moderator cleaning 500 objects still works in batches of at most 64 per op against a 60-burst, 10-refill bucket.
    Better than 500 taps, worse than a lasso, and the middle case is where a real defacement lives.
14. **`MANAGE_CANVAS` has no discoverability.** An operator ticking a checkbox whose label was written when the bit was cosmetic gets no signal that it is now the difference between a defaceable and a moderatable canvas.

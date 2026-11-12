# Voice Canvas spike: the server half

Status: measured, bet holds with one correction.
Date: 2026-07-26.
Scope: the [Phase 5](../ROADMAP.md) deliverable "the server-side R-Tree viewport query and a viewport-delta subscription protocol prototyped so panning a large world streams region objects rather than only the join viewport".
The client half (in-memory culling, 60fps at the soft caps) is [canvas-spike-client.md](canvas-spike-client.md) and is not decided here.

## The bet

That a SQLite R-Tree can answer viewport queries over a large canvas fast enough that panning streams only the objects in the region being entered, instead of the client fetching a whole world at join.

The roadmap's soft caps are roughly 5,000 objects on iOS and 20,000 on Linux, per canvas.

## Verdict

The bet holds, but not for the reason it was made, and not everywhere.

At a screenful of content the R-Tree read is flat at about 0.25 ms from 1,000 objects to 100,000, while a plain bounding-box scan of the same channel grows linearly and reaches 6.7 ms at 100,000.
At the 20,000 soft cap specifically the gap is 6.3x (0.25 ms against 1.56 ms).
That is the shape you want: cost proportional to what comes back, not to what exists.

The correction is that at 20,000 objects the scan is already fast enough on its own.
1.56 ms is not a problem for a pan.
What actually makes the index worth having is not the soft cap, it is everything the soft cap is not: canvases that outgrow it, deployments with several canvases sharing one index, and the fact that a panning client fires this query continuously rather than once.
If the argument for the R-Tree had to rest on 20,000 objects in one channel, it would be a weak argument, and it is worth saying so plainly.

Where it falls over is the viewport shape, not the object count.
The R-Tree loses to the plain scan once the viewport is about eight screens wide, and it is 1.7x slower than the scan at whole-world zoom.
Details below.

## What was built

Migration `0015_canvas_rtree.sql`, the store module `src/store/canvas.rs`, the route `GET /channels/{channelId}/canvas/objects`, and its schema entry.
`canvas_objects` and `canvas_ops` were created by 0002 in the first schema pass and nothing had ever written to either, so this is the first code to use them.

### Bridging (channel_id, seq) to an R-Tree's single integer

An R-Tree is keyed by one integer.
`canvas_objects` is `STRICT`, keyed by `(channel_id, seq)`, and its identity column is a 16-byte UUIDv7 blob.
0002 left it a rowid table on purpose, so the implicit rowid was the intended bridge.

That bridge was not taken.
SQLite documents VACUUM as free to renumber the rowids of any table with no explicit `INTEGER PRIMARY KEY`, and an R-Tree's shadow tables would be copied across unchanged, so every entry would silently come to point at a different object.
The first place that lands is the `VACUUM INTO` hot copy the Phase 9 backup story is built on, which means a wrong index in a backup nobody reads until a restore.

Measured rather than assumed: SQLite 3.46 (the version libsqlite3-sys bundles) preserved the rowids of a table with no `INTEGER PRIMARY KEY` through both `VACUUM` and `VACUUM INTO`, on this exact schema with 20,000 rows, and `PRAGMA integrity_check` came back clean.
So this is a licence the implementation has not taken, not a bug being fixed.
Building a spatial index on a licence is still the wrong trade, and withdrawing it costs nothing: `canvas_objects` now carries an explicit `rt_id INTEGER PRIMARY KEY`, which is an alias for the rowid and is never renumbered.

Adding it meant recreating the table, which is why the migration drops and recreates rather than altering.
That is safe precisely because nothing has ever written a canvas row: the only statement in the codebase that touches the table is the account-anonymization `UPDATE` in `store/sessions.rs`, which matches zero rows on every deployment that exists.

### Triggers, not writes alongside the insert

The index is maintained by three triggers on `canvas_objects`.
The reason is that the interesting writes are the ones no Rust code performs.
`canvas_objects` carries `ON DELETE CASCADE` from `channels`, so a hard channel delete removes rows without any application code running.
Phase 6 materializes this table from an append-only op log and compacts it on a schedule.
Moderation deletes arrive by their own path.
A trigger also runs inside the same transaction as the write, so the index cannot be left stale by a failure between two statements.

This is not a hypothetical: the whole measurement harness seeds by raw SQL in one transaction and never calls the store, and the index is correct anyway.
`tests/it_canvas/canvas_index.rs` asserts exactly that with a raw `INSERT` and a raw `DELETE`.

The update trigger is scoped with `AFTER UPDATE OF x, y, w, h, channel_key, deleted_at`.
Unscoped, deleting an account would rewrite every R-Tree entry that account ever authored, because anonymization nulls `author_id` on every one of their objects.

### A third dimension for the channel

One R-Tree serves the whole deployment, and every canvas starts at the same origin, so without a channel dimension a viewport read in one channel walks every other channel's canvas.
`canvas_objects` carries `channel_key`, a 24-bit discriminant of the channel id drawn from the UUIDv7's random tail (not its timestamp prefix, which channels created in the same millisecond share), and the R-Tree indexes it as a third dimension with `min_key = max_key = channel_key`.

24 bits because R-Tree coordinates are 32-bit floats, which hold integers below 2^24 exactly.
Collisions cost pruning only and never correctness, because `o.channel_id = ?` is still compared exactly in the query.

It is a column on the object rather than a lookup into `channels` so that the trigger is a plain `NEW.channel_key` read.
The alternative needs either a subquery per insert or a hash function SQLite does not have.

### The float32 hazard, and why it is safe

R-Tree coordinates are 32-bit floats and SQLite rounds a stored bounding box outwards, so far from the origin the index reports objects that are not really in the viewport.
That is safe in exactly one direction: it may over-report and can never under-report.
Every query therefore repeats the intersection test in exact `REAL` arithmetic against `canvas_objects`, and the R-Tree is only ever a way to avoid looking at most rows.

`tests/it_canvas/canvas_index.rs` places an object at x = 4,000,000.6 (where one float32 step is a quarter of a pixel), asserts the R-Tree does return it for a viewport ending at 4,000,000.5, and asserts the store does not.
The test fails if the coordinates stop exercising over-reporting, so it cannot rot into a test that passes for the wrong reason.

## Does it actually use the R-Tree

Yes, and only because the join order is pinned.
This is the single most important finding in the spike.

`EXPLAIN QUERY PLAN` on the query the store runs, against a database nothing has ever `ANALYZE`d, which is every slim-m deployment:

```
SCAN r VIRTUAL TABLE INDEX 2:B4D5D1B0D3B2
SEARCH o USING INTEGER PRIMARY KEY (rowid=?)
USE TEMP B-TREE FOR ORDER BY
```

`idxNum = 2` is SQLite's rtree module reporting its spatial strategy, and the string after it is one two-character term per constraint pushed down into the tree.
From `rtree.c`, the first character is the operator (`B` = LE, `D` = GE) and the second is the zero-based coordinate column (`min_x` 0, `max_x` 1, `min_y` 2, `max_y` 3, `min_key` 4, `max_key` 5).
So `B4 D5 D1 B0 D3 B2` decodes to `min_key <= k`, `max_key >= k`, `max_x >= view.min_x`, `min_x <= view.max_x`, `max_y >= view.min_y`, `min_y <= view.max_y`.
All six bounds reach the index.

Change the one word `CROSS JOIN` back to `JOIN` and the same query on the same data plans like this instead:

```
SEARCH o USING INDEX canvas_objects_channel_live (channel_id=?)
SCAN r VIRTUAL TABLE INDEX 1:
USE TEMP B-TREE FOR ORDER BY
```

`idxNum = 1` is the rtree module's other strategy: an equality constraint on its rowid, a single-row lookup.
The planner has decided to read every object in the channel and then probe the R-Tree once per row to confirm what it already has.
The spatial index prunes nothing.
It still returns the right answer, which is what makes it dangerous: nothing is wrong except the cost, and it costs 7.1x (1.78 ms against 0.25 ms), which is worse than having no spatial index at all.

The trap is that this only shows up on a database with no statistics.
`ANALYZE` was run once during investigation and the planner immediately picked the right plan by itself, which is exactly how this ships broken: it works on the developer's database and not on anyone's deployment.

`tests/it_canvas/canvas_index.rs` reads the SQL out of `src/store/canvas.rs` rather than carrying a copy, and asserts the plan drives from the R-Tree with all six terms.
A plan assertion against a copied query only proves the copy is fast.

## The numbers

Host: AMD Ryzen 9 9950X3D, Fedora 44, btrfs, 30 GiB RAM.
Build: `--release`.
SQLite 3.46.0, bundled statically by libsqlite3-sys 0.30.1, `SQLITE_ENABLE_RTREE` on by default in its bundled build.
WAL, `synchronous = NORMAL`, an 8-connection pool, which is `db::connect`'s production configuration.
Median of 30 runs after a warm-up, cache warm, one object per row and no attachments.
Objects are 180x140 on a jittered grid, and the world is sized so a 1920x1080 viewport holds about 200 of them, so the answer size is constant while the object count moves.

Reproduce with:

```
cargo nextest run --release --test it_canvas canvas_spike:: --run-ignored all --no-capture --test-threads=1
```

### Against object count, one screenful

| objects in the channel | rows returned | R-Tree | plain scan | ratio |
| --- | --- | --- | --- | --- |
| 1,000 | 252 | 0.24 ms | 0.26 ms | 1.1x |
| 5,000 | 250 | 0.24 ms | 0.52 ms | 2.2x |
| 20,000 | 250 | 0.25 ms | 1.56 ms | 6.3x |
| 100,000 | 249 | 0.27 ms | 6.72 ms | 25.3x |

The R-Tree is flat and the scan is linear, which is the whole point.
Note also what this says about the soft cap: 20,000 objects is not where SQLite has any trouble.

### Against zoom, at 20,000 objects

| viewport | rows returned | R-Tree | plain scan | ratio |
| --- | --- | --- | --- | --- |
| 1 screen | 250 | 0.25 ms | 1.55 ms | 6.1x |
| 2 screens | 901 | 0.88 ms | 2.30 ms | 2.6x |
| 4 screens | 2,000 (capped) | 2.41 ms | 3.20 ms | 1.3x |
| 8 screens | 2,000 (capped) | 4.64 ms | 3.84 ms | 0.8x |
| whole world | 2,000 (capped) | 6.47 ms | 3.93 ms | 0.6x |

This is where it falls over, and it is a viewport shape rather than an object count.
Somewhere between four and eight screens wide the R-Tree stops paying for itself, and at whole-world zoom it is 1.7x slower than just scanning, because it is walking the tree to reach nearly every leaf and then paying the rowid join on top.

The `LIMIT` is what keeps the absolute numbers bounded past four screens: both strategies still have to sort every match before the limit applies, which the `USE TEMP B-TREE FOR ORDER BY` in the plan is.
Nothing here is slow in absolute terms, but the crossover is real and a zoomed-out client would be paying for an index that is costing it.

### Against neighbouring canvases, 20,000 objects each

One read in the first channel, with more canvases in the same deployment-wide index.

| other canvases | 3 dimensions | 2 dimensions | ratio |
| --- | --- | --- | --- |
| 0 | 0.25 ms | 0.25 ms | 1.0x |
| 1 | 0.26 ms | 0.31 ms | 1.2x |
| 2 | 0.26 ms | 0.36 ms | 1.4x |
| 3 | 0.26 ms | 0.41 ms | 1.5x |
| 4 | 0.27 ms | 0.47 ms | 1.8x |

The channel dimension holds the read flat while the flat index degrades linearly in the number of canvases.
The absolute numbers are small at five canvases, but the slope is the point: a deployment with twenty voice channels would be paying 20x on a two-dimensional index, for a query the client fires on every pan.

### The pan delta

20,000 objects, panning right from a 1920-wide viewport.

| pan distance | cold fetch | delta | held back |
| --- | --- | --- | --- |
| 25% of a screen | 248 | 56 | 77% |
| 50% | 251 | 114 | 55% |
| 75% | 250 | 171 | 32% |
| 100% | 248 | 226 | 9% |

The residual at a full screen of pan is objects that straddle the boundary and so genuinely intersect both rectangles.
The delta tracks the overlap area, which is what it should do.

## The subscription protocol, and what it is not

`GET /channels/{channelId}/canvas/objects` takes the rectangle being entered, optionally the rectangle being left, and a `seq` cursor.
With no previous rectangle it is a cold fetch of the region.
With one it returns objects in the new rectangle that are not in the old one, plus anything inside both that is newer than the cursor.

Geometric difference is one extra predicate on rows the R-Tree has already narrowed, not four rectangles for the L-shaped remainder.
An object that intersects the leaving rectangle was already sent, so excluding it is a single intersection test.

It is a pull, not a server-held subscription, and that is a decision rather than a shortcut.
The client is the only party that knows when it panned.
A pull keeps no per-connection spatial state on the server to leak, to bound, or to rebuild after a reconnect, it composes with the per-scope cursor model `/sync` already uses, and a repeated pan is idempotent rather than a stream of corrections.
The WebSocket stays what it is: fan-out of things that happened, which a canvas client applies to whatever region it is holding.

### What it does not cover, and this is a real gap

The delta reports objects arriving.
It cannot report objects removed, because a soft delete does not advance the row's `seq`, so no cursor over `canvas_objects` can ever observe one.
A client that pans away and back would still be holding an object that was deleted while it was not looking.

The answer is the `canvas_ops` stream, where a delete is its own op with its own sequence, and Phase 6 already owns materializing this table from that log.
It is called out here rather than patched because patching it (a `deleted_seq` column, say) would build a second ordering authority alongside the op log that is meant to be the only one.

## What I would change

**Pin the join order, and keep the test that proves it.**
Already done, but it is worth restating as the standing recommendation: the `CROSS JOIN` is load-bearing and looks like style.
Any future edit to that query needs `tests/it_canvas/canvas_index.rs` to stay green, and the reason it reads the SQL out of the source is so a well-meant refactor cannot quietly leave the assertion checking something else.

**Have the client stop asking for the region past about four screens wide.**
The crossover is where the index stops helping, and the right response is not a different index, it is that nobody should be streaming a four-screen region object by object anyway.
That is a zoom level where the client wants a tile or a decimated overview, not 2,000 rows.
Phase 6 should decide what a zoomed-out canvas actually shows before it decides how to fetch it; if the answer is "everything", both strategies are the wrong shape, not just this one.

**Rate-limit this route before it ships to a real client.**
It is currently unmetered, like every other read in the codebase, and it is the only read a client fires continuously as a side effect of a gesture.
`Class::Write` is the wrong bucket and there is no read class yet.
Nothing measured here is slow enough to make that urgent, but the ordering matters: it wants doing before a client pans, not after.

**Reconsider whether `z_index` belongs in the `ORDER BY`.**
Every plan here ends in `USE TEMP B-TREE FOR ORDER BY`, so every viewport read sorts its whole match set before the limit applies.
At a screenful that is 250 rows and free.
At the zoomed-out shapes above it is most of the cost.
An index on `(channel_id, z_index, seq)` would not help, because the rows arrive from the R-Tree in spatial order and have to be collected before anything can be ordered.
Sorting on the client, which already holds a spatial index and a paint list, is probably the better place for it, but that is the client half's call to make.

**Do not put the `LIMIT` in the same place as the `has_more` flag forever.**
Right now a crowded region reports `has_more` and the client is told to ask for less, because there is no stable cursor across a region query.
That is honest but not friendly, and it is the interaction the previous point would change.

## What this does not answer

Concurrency.
Every number here is a single reader on an idle database.
The write path takes `BEGIN IMMEDIATE` and SQLite has one writer, so a room drawing at once serializes, and nothing here measures what a viewport read costs while that is happening.

Object payload.
The seeded objects carry `props = '{}'`.
A real stroke carries its point list, and a whole-region read is then bounded by bytes rather than rows, which changes where the sensible limit sits.

Cold cache.
Everything above is warm.
The first pan after a server restart reads pages off disk, and on the arm64 self-host boards this project targets that is a different machine as well as a different cache state.

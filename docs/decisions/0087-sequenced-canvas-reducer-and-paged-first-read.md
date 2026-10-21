<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0087 - One sequenced canvas reducer, and a paged first read

Status: accepted
Date: 2026-10-21

## The ask

The full canvas audit found the client diverging from the server in 20 to 45 percent of the seeds of a seeded fuzz over a hostile network.
Point patches to the three paths that change the board (live frames, catch-up pages, viewport pages) cut that to 2 to 3 percent.
The owner's answers on 2026-10-21: every viewer converges on the same board, and a big board loads the visible area first, then pages in the rest with a small quiet "loaded / total objects" count.

## Decision: one reducer

`CanvasSync` is the only thing that moves the cursor, and every path that changes the document goes through it.

- A live frame is ignored before the first read has seeded the cursor, and ignored when it is at or below the cursor.
  The next op (cursor plus one) is applied.
  A later one waits in a buffer while a catch-up fetches what is between, and applies when the gap closes.
- A catch-up page applies its ops in order and moves the cursor as each lands, skipping any at or below it.
  A page that is slow can no longer replay old ops over newer live ones.
  A catch-up asked for while one runs sets a flag and runs again, so the last op of a burst is never lost.
  With no cursor yet it does nothing.
- A viewport page is applied against the cursor.
  The first read seeds it.
  A page older than the cursor is brought forward by re-applying the recent ops it predates (a bounded log of the last 1024), or read again when the log no longer reaches back or a restore landed after it.
  A page at or past the cursor is authoritative for the box, text and order of the objects it lists, and, once the document has caught up to it, drops what the document shows inside the region but the page does not list.
- A tombstone remembers the seq of the op that made it.
  A snapshot taken at or after that seq which still lists the object says it was restored since, so it comes back.
  A tombstone whose seq is not known yet (an erase still on its way to the server) is never lifted by a snapshot.
- The document remembers the seq it is reflected up to.
  A placement reply at or below it for an object the document does not hold is refused, since the object was removed after it was placed.
  A clear that arrived while a placement was still unconfirmed sweeps that placement when its reply lands.
- A committed move settles the drag preview of its object on every path, including a frame the cursor ignores and a catch-up page.
  A preview frame that straggles in just after the commit is ignored for a second.
- A hard reset a second time inside the five-second floor is postponed to the end of it, not dropped.
  The floor is measured on a monotonic clock.
- A write the server refused, or only partly carried out, reads the region again, since rolling back to the box the gesture started from can undo a newer remote move.

The seeded fuzz (`canvas_engine_fuzz_test.dart`, 200 seeds in each of four configurations, run in under ten seconds) holds the engine to this and passes with no divergence.
Seeds 400 to 1400 were also run once: one seed of 4000 still ended with a box left where a remote drag preview put it, which is left to a later pass.

## Decision: a paged first read

The first read of a canvas is the padded visible area, as before.
Once it lands the engine reads the rest of the board in the background: the board first, then the strips of world around it, splitting any tile the server could not return whole.
The count ("120 / 480 objects", or "120 objects loaded" when the server does not report a total) is a small pill at the top of the canvas, only while paging.
A tile that stays crowded at the smallest size leaves the existing "some ink is not shown" notice up.
When paging finishes the whole world counts as fetched, so panning no longer reads again.
`total_objects` is an optional field on the viewport read; the client uses it when the server sends it.

## Not done

- The server does not yet send `total_objects` or a stable cursor across a region read, so a crowded region is split by area rather than paged.
- The lock and media-slot frames still carry no ordering (C-165), which needs a server change.

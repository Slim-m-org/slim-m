-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The shared frame of a module tile on a canvas (kind 'module'): the module's
-- last successful scene for that object, which every viewer draws, and the
-- next host redraw when the scene asks for one (refresh_ms). Current state,
-- not history, so its own table like canvas_object_locks; a failed press
-- answers its presser and never lands here.
--
-- It follows the object on a hard delete. A removed object keeps its frame,
-- so an undo brings the tile back as it was.
CREATE TABLE canvas_tile_scenes (
    object_id        BLOB PRIMARY KEY REFERENCES canvas_objects(id) ON DELETE CASCADE,
    channel_id       BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    output           TEXT NOT NULL,
    ran_by           BLOB REFERENCES users(id) ON DELETE SET NULL,
    ran_at           INTEGER NOT NULL,
    refresh_due_at   INTEGER,
    refresh_until_at INTEGER
) STRICT, WITHOUT ROWID;

CREATE INDEX canvas_tile_scenes_refresh_due ON canvas_tile_scenes(refresh_due_at)
    WHERE refresh_due_at IS NOT NULL;

-- The account-deletion sweep resolves ran_by to NULL by this column.
CREATE INDEX canvas_tile_scenes_ran_by ON canvas_tile_scenes(ran_by);

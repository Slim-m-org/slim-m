-- SPDX-License-Identifier: AGPL-3.0-only
-- Moves a canvas object's props, up to 4 KiB of opaque JSON, out of the row the
-- single writer rewrites on every clear, restore, move and reorder. The flip now
-- touches a small row, and the viewport read can sort and limit without
-- materialising props for every candidate.
--
-- `object_id` follows `canvas_objects(id)`, which is UNIQUE, and goes with it on a
-- hard delete. The soft-delete flag never touches this table.
CREATE TABLE canvas_object_props (
    object_id BLOB NOT NULL PRIMARY KEY REFERENCES canvas_objects(id) ON DELETE CASCADE,
    props     TEXT NOT NULL
) STRICT, WITHOUT ROWID;

INSERT INTO canvas_object_props (object_id, props) SELECT id, props FROM canvas_objects;

ALTER TABLE canvas_objects DROP COLUMN props;

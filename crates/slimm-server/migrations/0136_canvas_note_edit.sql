-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Adds `edit` to canvas_ops: a note's props replaced after placement (decision
-- 0072 reverses notes being fixed once placed). `edit_props` is the props the
-- edit wrote, so replaying the op log reaches the same note text. Same rebuild
-- shape as 0036: canvas_op_targets is saved aside and restored around the DROP,
-- since its ON DELETE CASCADE fires for a DROP TABLE under foreign_keys=ON.
CREATE TABLE canvas_op_targets_rebuild AS
    SELECT channel_id, seq, object_id FROM canvas_op_targets;
CREATE TABLE canvas_ops_rebuild AS
    SELECT channel_id, seq, id, kind, actor_id, bound_seq, target_op,
           move_x, move_y, move_w, move_h, reorder_z, created_at
    FROM canvas_ops;
DELETE FROM canvas_op_targets; -- NOSONAR
DROP TABLE canvas_ops;
CREATE TABLE canvas_ops (
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    id         BLOB NOT NULL UNIQUE,
    kind       TEXT NOT NULL,
    actor_id   BLOB REFERENCES users(id) ON DELETE SET NULL,
    bound_seq  INTEGER,
    target_op  BLOB REFERENCES canvas_ops(id),
    move_x     REAL,
    move_y     REAL,
    move_w     REAL,
    move_h     REAL,
    reorder_z  INTEGER,
    edit_props TEXT,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (channel_id, seq),
    CONSTRAINT canvas_op_kind
        CHECK (kind IN ('place', 'remove', 'clear', 'restore', 'move', 'reorder', 'edit')),
    CONSTRAINT canvas_op_bound
        CHECK ((kind = 'clear') = (bound_seq IS NOT NULL)),
    CONSTRAINT canvas_op_target
        CHECK ((kind = 'restore') = (target_op IS NOT NULL)),
    CONSTRAINT canvas_op_move_bounds
        CHECK ((kind = 'move') = (move_x IS NOT NULL AND move_y IS NOT NULL
                                   AND move_w IS NOT NULL AND move_h IS NOT NULL)),
    CONSTRAINT canvas_op_reorder_z
        CHECK ((kind = 'reorder') = (reorder_z IS NOT NULL)),
    CONSTRAINT canvas_op_edit_props
        CHECK ((kind = 'edit') = (edit_props IS NOT NULL))
) STRICT, WITHOUT ROWID;
INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, bound_seq, target_op,
                         move_x, move_y, move_w, move_h, reorder_z, created_at)
    SELECT channel_id, seq, id, kind, actor_id, bound_seq, target_op,
           move_x, move_y, move_w, move_h, reorder_z, created_at
    FROM canvas_ops_rebuild;
CREATE INDEX canvas_ops_author
    ON canvas_ops(actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX canvas_ops_kind_created_at ON canvas_ops(kind, created_at);
CREATE INDEX canvas_ops_target_op ON canvas_ops(target_op) WHERE target_op IS NOT NULL;
INSERT INTO canvas_op_targets (channel_id, seq, object_id)
    SELECT channel_id, seq, object_id FROM canvas_op_targets_rebuild;
CREATE TABLE canvas_ops_rebuild_guard (
    ops     INTEGER NOT NULL CONSTRAINT canvas_ops_row_count_changed CHECK (ops = 0),
    targets INTEGER NOT NULL CONSTRAINT canvas_op_targets_row_count_changed CHECK (targets = 0)
) STRICT;
INSERT INTO canvas_ops_rebuild_guard (ops, targets) VALUES (
    (SELECT count(*) FROM canvas_ops) - (SELECT count(*) FROM canvas_ops_rebuild),
    (SELECT count(*) FROM canvas_op_targets) - (SELECT count(*) FROM canvas_op_targets_rebuild)
);
DROP TABLE canvas_ops_rebuild_guard;
DROP TABLE canvas_ops_rebuild;
DROP TABLE canvas_op_targets_rebuild;

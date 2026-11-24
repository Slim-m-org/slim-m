-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Canvas edges (decision 0137): which objects each end of an `edge` object is attached to, and
-- which edges fell with an erase or a clear without being named by it.
-- Derived from the edge's props on place and edit; the props stay the source of truth. The side
-- table exists so an erase and a move can find "edges touching these objects" by index.
CREATE TABLE canvas_edge_ends (
    edge_id   BLOB NOT NULL REFERENCES canvas_objects(id) ON DELETE CASCADE,
    endpoint  TEXT NOT NULL CHECK (endpoint IN ('from', 'to')),
    object_id BLOB NOT NULL REFERENCES canvas_objects(id) ON DELETE CASCADE,
    PRIMARY KEY (edge_id, endpoint)
) STRICT, WITHOUT ROWID;

CREATE INDEX canvas_edge_ends_object ON canvas_edge_ends(object_id);

-- The edges one remove or clear took with it. Kept apart from canvas_op_targets so the op's own
-- object ids stay the directly erased ones and a remove frame keeps its 64 id bound.
CREATE TABLE canvas_op_cascades (
    channel_id BLOB NOT NULL,
    seq        INTEGER NOT NULL,
    object_id  BLOB NOT NULL REFERENCES canvas_objects(id) ON DELETE CASCADE,
    PRIMARY KEY (channel_id, seq, object_id),
    FOREIGN KEY (channel_id, seq)
        REFERENCES canvas_ops(channel_id, seq) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

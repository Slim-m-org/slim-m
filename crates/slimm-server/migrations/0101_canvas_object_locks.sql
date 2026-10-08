-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A canvas object someone locked in place: nobody moves, restacks or erases
-- it until it is unlocked, and the client lets pointers pass through it so a
-- photo can be layered or drawn on top (decision 0017 gives every item lock).
-- Its own table rather than a canvas_objects column or a canvas_ops kind, the
-- same reasons as canvas_media_slots: it is current state, not history, and a
-- new op kind would mean rebuilding canvas_ops for its CHECK constraint.
CREATE TABLE canvas_object_locks (
    object_id  BLOB PRIMARY KEY REFERENCES canvas_objects(id) ON DELETE CASCADE,
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    locked_by  BLOB REFERENCES users(id) ON DELETE SET NULL,
    locked_at  INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX canvas_object_locks_channel ON canvas_object_locks(channel_id);

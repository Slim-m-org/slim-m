-- SPDX-License-Identifier: AGPL-3.0-only
-- A replayed clear must report what the original did, which the mutable
-- deleted_at fence stops answering once the clear is undone, so the count is stored.
ALTER TABLE canvas_ops ADD COLUMN affected INTEGER;
UPDATE canvas_ops SET affected = (
    SELECT COUNT(*) FROM canvas_objects o
    WHERE o.channel_id = canvas_ops.channel_id
      AND o.seq <= canvas_ops.bound_seq
      AND o.deleted_at = canvas_ops.created_at
) WHERE kind = 'clear';
-- The retention sweep and the clear fences read dead rows only.
CREATE INDEX canvas_objects_dead ON canvas_objects(deleted_at) WHERE deleted_at IS NOT NULL;

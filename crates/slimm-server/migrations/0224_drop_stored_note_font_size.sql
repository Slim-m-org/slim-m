-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The app wrote a note's box-derived font_size on placement; it is now honoured, so the stale ones go and notes scale with their box again.
UPDATE canvas_object_props
   SET props = json_remove(props, '$.font_size')
 WHERE json_type(props, '$.font_size') IS NOT NULL
   AND object_id IN (SELECT id FROM canvas_objects WHERE kind = 'note');

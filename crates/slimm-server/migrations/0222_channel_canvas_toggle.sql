-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Canvas channels and the voice canvas toggle (decision 0139). canvas_enabled is read for voice channels only, voice_enabled for canvas channels only.
ALTER TABLE channels ADD COLUMN canvas_enabled INTEGER NOT NULL DEFAULT 0
    CHECK (canvas_enabled IN (0, 1));
ALTER TABLE channels ADD COLUMN voice_enabled INTEGER NOT NULL DEFAULT 0
    CHECK (voice_enabled IN (0, 1));
UPDATE channels SET canvas_enabled = 1
 WHERE kind = 'voice'
   AND EXISTS (SELECT 1 FROM canvas_objects o
                WHERE o.channel_id = channels.id AND o.deleted_at IS NULL);

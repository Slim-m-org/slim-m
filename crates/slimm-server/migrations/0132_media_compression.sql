-- SPDX-License-Identifier: AGPL-3.0-only
-- The space's choice to shrink photos on upload. Off by default so a deployment
-- keeps storing uploads byte for byte until an admin turns it on. An empty type
-- list means the built-in photo formats; the metadata mode is only read while
-- compression is on. The original columns record a kept copy of what was sent:
-- original_size 0 means none was kept.
ALTER TABLE space_settings ADD COLUMN media_compress INTEGER NOT NULL DEFAULT 0
    CHECK (media_compress IN (0, 1));
ALTER TABLE space_settings ADD COLUMN media_compress_types TEXT NOT NULL DEFAULT '';
ALTER TABLE space_settings ADD COLUMN media_metadata TEXT NOT NULL DEFAULT 'remove_location'
    CHECK (media_metadata IN ('keep', 'remove_location', 'remove_all'));
ALTER TABLE space_settings ADD COLUMN media_keep_original INTEGER NOT NULL DEFAULT 0
    CHECK (media_keep_original IN (0, 1));

ALTER TABLE attachments ADD COLUMN original_size INTEGER NOT NULL DEFAULT 0
    CHECK (original_size >= 0);
ALTER TABLE attachments ADD COLUMN original_content_type TEXT NOT NULL DEFAULT '';
ALTER TABLE attachments ADD COLUMN original_filename TEXT NOT NULL DEFAULT '';

-- SPDX-License-Identifier: AGPL-3.0-only
-- An optional welcome message posted when someone joins, off by default so a
-- deployment never gets behaviour it did not ask for. The template is capped
-- in Rust so the limit can move without a migration. welcome_author_id is the
-- webhook-shaped principal the post is attributed to, created on first use.
ALTER TABLE space_settings ADD COLUMN welcome_enabled INTEGER NOT NULL DEFAULT 0
    CHECK (welcome_enabled IN (0, 1));
ALTER TABLE space_settings ADD COLUMN welcome_channel_id BLOB
    REFERENCES channels(id) ON DELETE SET NULL;
ALTER TABLE space_settings ADD COLUMN welcome_message TEXT NOT NULL DEFAULT '';
ALTER TABLE space_settings ADD COLUMN welcome_author_id BLOB
    REFERENCES users(id) ON DELETE SET NULL;

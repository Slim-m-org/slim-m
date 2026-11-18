-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- One account's mute of a whole category: every channel filed under it, or
-- under one of its sub-categories, is quiet for that account unless it has its
-- own per-channel choice (channel_notification_prefs, which always wins).
--
-- Resolved when a message fans out rather than copied into a row per channel,
-- so a channel added to or moved into the category later is covered too.
CREATE TABLE category_mutes (
    user_id     BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id BLOB NOT NULL REFERENCES channel_categories(id) ON DELETE CASCADE,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (user_id, category_id)
) STRICT, WITHOUT ROWID;

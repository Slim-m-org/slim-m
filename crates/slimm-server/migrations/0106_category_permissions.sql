-- SPDX-License-Identifier: AGPL-3.0-only
-- Category permissions (decision 0064): a category holds overwrites shaped
-- like a channel's, and a synced channel carries an exact copy of them.
-- Every existing channel starts unsynced, so nothing changes on upgrade.
CREATE TABLE category_overwrites (
    category_id BLOB NOT NULL REFERENCES channel_categories(id) ON DELETE CASCADE,
    target_type TEXT NOT NULL,
    target_id   BLOB NOT NULL,
    allow       INTEGER NOT NULL DEFAULT 0,
    deny        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (category_id, target_type, target_id)
) STRICT, WITHOUT ROWID;

ALTER TABLE channels ADD COLUMN permissions_synced INTEGER NOT NULL DEFAULT 0;

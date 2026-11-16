-- SPDX-License-Identifier: AGPL-3.0-only
-- A soundboard clip's emoji, shown beside its name (decision 0118): one
-- standard emoji, or a custom emoji's id, cleared when that emoji is deleted.
-- Null means the clip has none.
ALTER TABLE soundboard_clips ADD COLUMN emoji TEXT;

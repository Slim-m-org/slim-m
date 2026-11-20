-- SPDX-License-Identifier: AGPL-3.0-only
-- Which player a watch party's item belongs to (docs/decisions/0050, 0128):
-- 'jellyfin' for a Jellyfin item id, 'youtube' for a YouTube video id that
-- each viewer plays in YouTube's own embed. Every older row is Jellyfin's.
ALTER TABLE watch_sessions ADD COLUMN provider TEXT NOT NULL DEFAULT 'jellyfin'
    CHECK (provider IN ('jellyfin', 'youtube'));

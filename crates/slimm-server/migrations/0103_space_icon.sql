-- SPDX-License-Identifier: AGPL-3.0-only
-- The space's square icon, shown beside its name on the landing card and in
-- the space menu. The bytes live in the media root; this only records when
-- they were set.
ALTER TABLE space_settings ADD COLUMN icon_updated_at INTEGER;

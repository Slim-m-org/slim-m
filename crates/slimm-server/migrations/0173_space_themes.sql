-- SPDX-License-Identifier: AGPL-3.0-only
-- The Space theme store (decision 0106): themes members publish, and the
-- Space's default theme.
--
-- The backdrop picture is a column, not an `attachments` row. The emoji path
-- (0016, 0017) shows what sharing that table costs: the orphan sweep, the
-- export and account deletion each need an exclusion for it. The picture is
-- capped at 2 MiB and the table at 50 rows, so a column keeps it out of all
-- three.
CREATE TABLE space_themes (
    id           BLOB PRIMARY KEY,
    name         TEXT NOT NULL,
    author_id    BLOB REFERENCES users(id) ON DELETE SET NULL,
    author_name  TEXT NOT NULL,
    doc          TEXT NOT NULL,
    picture      BLOB,
    picture_type TEXT,
    created_at   INTEGER NOT NULL
) STRICT;

ALTER TABLE space_settings
    ADD COLUMN default_theme_id BLOB REFERENCES space_themes(id) ON DELETE SET NULL;

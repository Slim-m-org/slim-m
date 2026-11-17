-- SPDX-License-Identifier: AGPL-3.0-only
-- The soundboard (decision 0118): short audio clips the Space owns and any
-- member with USE_SOUNDBOARD may play into a call they are in.
--
-- Shaped like `custom_emoji` (0016): the bytes are a content-addressed
-- `attachments` row, so the storage, the sniffing and the orphan sweep are the
-- ones attachments already have, and this table adds the name and the
-- duration the upload was validated at.
CREATE TABLE soundboard_clips (
    id          BLOB PRIMARY KEY,
    name        TEXT NOT NULL COLLATE NOCASE,
    sha256      BLOB NOT NULL REFERENCES attachments(sha256) ON DELETE RESTRICT,
    duration_ms INTEGER NOT NULL,
    uploader_id BLOB REFERENCES users(id) ON DELETE SET NULL,
    created_at  INTEGER NOT NULL
) STRICT;

CREATE UNIQUE INDEX soundboard_clips_name ON soundboard_clips(name);
CREATE INDEX soundboard_clips_by_sha ON soundboard_clips(sha256);

-- USE_SOUNDBOARD (1 << 21) for every existing @everyone role.
UPDATE roles SET permissions = permissions | 2097152 WHERE is_everyone = 1;

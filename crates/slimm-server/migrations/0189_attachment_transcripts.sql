-- The text of a voice message. One row per blob, so every message carrying
-- the same bytes shares it; the cascade drops it with the blob, which is how it
-- follows message delete and retention. The words themselves are also indexed
-- in `attachment_text_fts` for search; a transcript with no words has an empty text.
CREATE TABLE attachment_transcripts (
    sha256     BLOB PRIMARY KEY REFERENCES attachments(sha256) ON DELETE CASCADE,
    status     TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'failed')),
    text       TEXT NOT NULL DEFAULT '',
    language   TEXT,
    updated_at INTEGER NOT NULL
) STRICT;

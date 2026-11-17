-- A voice message is an audio attachment the client recorded in the composer.
-- Side table, not columns on `attachments` (content-addressed rows are read by
-- many queries that never need this). One row per blob; the cascade drops it
-- with the blob, so it follows message delete and retention.
CREATE TABLE attachment_voice (
    sha256      BLOB PRIMARY KEY REFERENCES attachments(sha256) ON DELETE CASCADE,
    duration_ms INTEGER NOT NULL CHECK (duration_ms > 0),
    -- 64 one-byte loudness buckets, drawn by the client without decoding.
    waveform    BLOB NOT NULL CHECK (length(waveform) = 64)
) STRICT;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Call transcripts kept by the server (decision 0113): one row per transcription
-- session, its spoken lines (`id` is the rowid alias the index points at, so a
-- VACUUM cannot renumber it), a full-text index over the lines, the two Space
-- settings, and the VIEW_TRANSCRIPTS permission (1 << 20) for @everyone.
CREATE TABLE call_transcripts (
    id         BLOB PRIMARY KEY,
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    started_at INTEGER NOT NULL,
    ended_at   INTEGER,
    mode       TEXT NOT NULL CHECK (mode IN ('on_request', 'always')),
    started_by BLOB REFERENCES users(id) ON DELETE SET NULL
) STRICT;
CREATE INDEX call_transcripts_channel_idx ON call_transcripts (channel_id, started_at);
CREATE INDEX call_transcripts_ended_idx ON call_transcripts (ended_at) WHERE ended_at IS NOT NULL;

CREATE TABLE call_transcript_lines (
    id            INTEGER PRIMARY KEY,
    transcript_id BLOB NOT NULL REFERENCES call_transcripts(id) ON DELETE CASCADE,
    seq           INTEGER NOT NULL,
    speaker_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    at            INTEGER NOT NULL,
    text          TEXT NOT NULL,
    UNIQUE (transcript_id, seq)
) STRICT;
CREATE INDEX call_transcript_lines_speaker_idx ON call_transcript_lines (speaker_id);

CREATE VIRTUAL TABLE call_transcript_lines_fts USING fts5(
    text,
    content='call_transcript_lines',
    content_rowid='id',
    tokenize='unicode61'
);

CREATE TRIGGER call_transcript_lines_fts_ai AFTER INSERT ON call_transcript_lines BEGIN
    INSERT INTO call_transcript_lines_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;

CREATE TRIGGER call_transcript_lines_fts_ad AFTER DELETE ON call_transcript_lines BEGIN
    INSERT INTO call_transcript_lines_fts(call_transcript_lines_fts, rowid, text)
        VALUES ('delete', OLD.id, OLD.text);
END;

CREATE TRIGGER call_transcript_lines_fts_au AFTER UPDATE OF text ON call_transcript_lines BEGIN
    INSERT INTO call_transcript_lines_fts(call_transcript_lines_fts, rowid, text)
        VALUES ('delete', OLD.id, OLD.text);
    INSERT INTO call_transcript_lines_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;

ALTER TABLE space_settings ADD COLUMN call_transcription TEXT NOT NULL DEFAULT 'off'
    CHECK (call_transcription IN ('off', 'on_request', 'always'));
ALTER TABLE space_settings ADD COLUMN call_transcript_retention_days INTEGER DEFAULT 30
    CHECK (call_transcript_retention_days IS NULL OR call_transcript_retention_days >= 1);

UPDATE roles SET permissions = permissions | 1048576 WHERE is_everyone = 1;

-- When a member acknowledged the one-time notice that the Space transcribes calls.
ALTER TABLE users ADD COLUMN transcription_notice_ack_at INTEGER;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Marks and notes on a call's transcript (decision 0113, amended 2026-11-22): a
-- moment someone in the call marked, with an optional note. A side table, so a
-- transcript line row never grows. Readable by whoever may read the transcript.
CREATE TABLE call_transcript_marks (
    id            BLOB PRIMARY KEY,
    transcript_id BLOB NOT NULL REFERENCES call_transcripts(id) ON DELETE CASCADE,
    author_id     BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    at            INTEGER NOT NULL,
    line_seq      INTEGER,
    kind          TEXT NOT NULL CHECK (kind IN ('mark', 'note')),
    text          TEXT CHECK (text IS NULL OR length(text) <= 500),
    source        TEXT NOT NULL CHECK (source IN ('voice', 'manual')),
    created_at    INTEGER NOT NULL,
    CHECK ((kind = 'note') = (text IS NOT NULL))
) STRICT;
CREATE INDEX call_transcript_marks_transcript_idx ON call_transcript_marks (transcript_id, at);
CREATE INDEX call_transcript_marks_author_idx ON call_transcript_marks (author_id);

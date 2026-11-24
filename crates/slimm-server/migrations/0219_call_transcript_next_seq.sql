-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A transcript's line counter, so a deleted newest line never hands its seq to the next one.
ALTER TABLE call_transcripts ADD COLUMN next_seq INTEGER NOT NULL DEFAULT 0;
UPDATE call_transcripts SET next_seq = COALESCE(
    (SELECT MAX(seq) FROM call_transcript_lines WHERE transcript_id = call_transcripts.id), 0);

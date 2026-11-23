-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- `GET /me/call-stats` reads one speaker's lines from a start time on; (speaker_id, at)
-- makes that bound a range of the index instead of a filter over every line the member
-- ever spoke. It also serves every lookup by speaker alone, so the old index goes.
CREATE INDEX call_transcript_lines_speaker_at_idx ON call_transcript_lines (speaker_id, at);
DROP INDEX call_transcript_lines_speaker_idx;

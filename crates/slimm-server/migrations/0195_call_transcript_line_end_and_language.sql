-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- When each call transcript line ended and the language the listener heard in
-- it (decision 0113). Both stay null on lines written before this migration.
ALTER TABLE call_transcript_lines ADD COLUMN end_at INTEGER;
ALTER TABLE call_transcript_lines ADD COLUMN language TEXT;

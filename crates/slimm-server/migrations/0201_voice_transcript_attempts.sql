-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- How many times a listener that took a voice clip failed it. Kept here rather
-- than in the worker's memory, so a restart does not hand a failing clip a fresh
-- set of tries and the cap in `voice_transcripts::MAX_ATTEMPTS` still holds.
ALTER TABLE attachment_transcripts ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0;

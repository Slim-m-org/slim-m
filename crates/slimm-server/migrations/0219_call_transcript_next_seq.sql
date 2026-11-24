-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A transcript's line counter, so a deleted newest line never hands its seq to the next one.
ALTER TABLE call_transcripts ADD COLUMN next_seq INTEGER NOT NULL DEFAULT 0;
UPDATE call_transcripts SET next_seq = COALESCE(
    (SELECT MAX(seq) FROM call_transcript_lines WHERE transcript_id = call_transcripts.id), 0);

-- Erased canvas objects by channel and placement order, so the per-placement ceiling count and the oldest-first eviction never walk the whole deployment.
CREATE INDEX canvas_objects_channel_erased ON canvas_objects(channel_id, seq) WHERE deleted_at IS NOT NULL;
-- Eviction skips objects a moderator's audit rows still name.
CREATE INDEX canvas_audit_log_object ON canvas_audit_log(object_id);

-- A fail-closed hook that keeps failing is kept on and counted apart, so it cannot trip the breaker for the module's other runs.
ALTER TABLE module_health ADD COLUMN hook_failures INTEGER NOT NULL DEFAULT 0;

-- When a sweep last began a pass, so a pass that crashed the process still waits its interval after the next boot.
CREATE TABLE sweep_attempts (
    name         TEXT NOT NULL PRIMARY KEY,
    attempted_at INTEGER NOT NULL
) STRICT;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Spoken marks (decision 0113, amended 2026-11-22): a per-Space switch, off by
-- default, and its editable wake phrase. Turning the switch on stamps when the
-- transcription notice changed, so it is owed again to everyone who saw it.
ALTER TABLE space_settings ADD COLUMN voice_commands INTEGER NOT NULL DEFAULT 0
    CHECK (voice_commands IN (0, 1));
ALTER TABLE space_settings ADD COLUMN voice_command_phrase TEXT NOT NULL DEFAULT 'hey space'
    CHECK (length(voice_command_phrase) BETWEEN 3 AND 40);
ALTER TABLE space_settings ADD COLUMN transcription_notice_revised_at INTEGER;

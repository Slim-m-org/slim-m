-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A voice message belongs to the message that carries it, not to the bytes.
-- Attachments are shared by content, so the one row per blob 0187 kept let
-- whoever uploaded some bytes first decide how every later message carrying
-- them rendered: another member's plain share of the same file showed as a
-- voice message. Each uploader now keeps what they sent the bytes as, a send
-- copies that onto its own link, and a forward copies the link it passes on,
-- the same move 0096 made for the filename.
ALTER TABLE attachment_uploaders ADD COLUMN voice_duration_ms INTEGER
    CHECK (voice_duration_ms > 0);
ALTER TABLE attachment_uploaders ADD COLUMN voice_waveform BLOB
    CHECK (length(voice_waveform) = 64)
    CHECK ((voice_waveform IS NULL) = (voice_duration_ms IS NULL));
ALTER TABLE message_attachments ADD COLUMN voice_duration_ms INTEGER
    CHECK (voice_duration_ms > 0);
ALTER TABLE message_attachments ADD COLUMN voice_waveform BLOB
    CHECK (length(voice_waveform) = 64)
    CHECK ((voice_waveform IS NULL) = (voice_duration_ms IS NULL));

-- The transcript sweep looks for voice links every few seconds.
CREATE INDEX message_attachments_voice ON message_attachments(sha256)
    WHERE voice_duration_ms IS NOT NULL;

-- Every message that shows as a voice message today keeps showing as one.
UPDATE message_attachments
SET voice_duration_ms = (SELECT v.duration_ms FROM attachment_voice v
                         WHERE v.sha256 = message_attachments.sha256),
    voice_waveform = (SELECT v.waveform FROM attachment_voice v
                      WHERE v.sha256 = message_attachments.sha256)
WHERE sha256 IN (SELECT sha256 FROM attachment_voice);

-- An upload not yet sent keeps its mark only where one uploader could have
-- asked for it; with several, nobody can tell who did, and a plain file is safe.
UPDATE attachment_uploaders
SET voice_duration_ms = (SELECT v.duration_ms FROM attachment_voice v
                         WHERE v.sha256 = attachment_uploaders.sha256),
    voice_waveform = (SELECT v.waveform FROM attachment_voice v
                      WHERE v.sha256 = attachment_uploaders.sha256)
WHERE sha256 IN (SELECT sha256 FROM attachment_voice)
  AND NOT EXISTS (SELECT 1 FROM attachment_uploaders other
                  WHERE other.sha256 = attachment_uploaders.sha256
                    AND other.uploaded_by != attachment_uploaders.uploaded_by);

DROP TABLE attachment_voice;

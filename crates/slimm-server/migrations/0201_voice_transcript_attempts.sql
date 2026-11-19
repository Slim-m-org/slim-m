-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- How many times a listener that took a voice clip failed it since the clip last
-- settled, so a restart does not hand a failing clip a fresh set of tries. Kept
-- apart from `attachment_transcripts`: a listener outage takes back the pending
-- mark there, so no message shows transcribing, and the count must outlive it.
CREATE TABLE voice_transcript_attempts (
    sha256   BLOB PRIMARY KEY REFERENCES attachments(sha256) ON DELETE CASCADE,
    attempts INTEGER NOT NULL CHECK (attempts > 0)
) STRICT;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- When a failed voice transcript is tried again. Set only when the worker gave
-- up after a listener that took the clip kept failing it; null for a clip the
-- listener refused, which is never tried again.
ALTER TABLE attachment_transcripts ADD COLUMN retry_at INTEGER;

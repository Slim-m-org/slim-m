-- SPDX-License-Identifier: AGPL-3.0-only
-- Whether a message shows one of its attachments behind a spoiler. It lives
-- on the link rather than the blob because the same bytes can ride on many
-- messages, and only the sender of this one chose to hide them here.
ALTER TABLE message_attachments ADD COLUMN spoiler INTEGER NOT NULL DEFAULT 0 CHECK (spoiler IN (0, 1));

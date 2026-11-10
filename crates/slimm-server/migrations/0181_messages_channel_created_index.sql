-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Retention prunes a channel with its own window by `created_at`, but
-- `messages_channel_live(channel_id, seq DESC)` has no time column, so every
-- sweep batch read all of that channel's live messages to find the few past
-- the window. This index seeks them by range instead, and lets the Space
-- window skip an exempt channel without walking its old messages.
-- Partial on `deleted_at IS NULL`, the shape of `messages_channel_live` and
-- `messages_live_created_at` (0044): a soft-deleted row is never a candidate.
CREATE INDEX messages_channel_created
    ON messages(channel_id, created_at) WHERE deleted_at IS NULL;

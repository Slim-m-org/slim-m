-- SPDX-License-Identifier: AGPL-3.0-only
-- Slow mode measures the window from an author's last send in a channel,
-- deleted messages included, so deleting a message cannot reopen the window.
-- `messages_author_channel_window` (0054) is partial on `deleted_at IS NULL`
-- and cannot answer that, so this is the same key without the predicate.
CREATE INDEX messages_author_channel_sent
    ON messages(channel_id, author_id, created_at);

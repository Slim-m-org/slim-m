-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The member a bot's message quotes or re-posts, so a viewer's blocks cover
-- the repost as they cover that member's own messages. Side table, like
-- 0073's webhook labels: most messages have no row. Written once, by the bot
-- that sent the message; nothing reads it back as an author.
CREATE TABLE message_repost_authors (
    message_id BLOB PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    author_id  BLOB NOT NULL REFERENCES users(id)
) STRICT;

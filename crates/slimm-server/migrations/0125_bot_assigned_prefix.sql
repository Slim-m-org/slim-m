-- SPDX-License-Identifier: AGPL-3.0-only
-- The prefix an admin assigned a bot when creating it, so two bots are never
-- left to pick the same one by accident. Null for a bot made before this
-- existed, until its first registration adopts the prefix it already uses.
-- Whether two bots may share a prefix is decided per command name at
-- registration, not here; see docs/decisions/0069-bot-prefix-assignment.md.
ALTER TABLE users ADD COLUMN bot_prefix TEXT
    CHECK (bot_prefix IS NULL OR length(bot_prefix) BETWEEN 1 AND 16);

UPDATE users
SET bot_prefix = (
    SELECT r.prefix FROM bot_command_registrations r WHERE r.bot_user_id = users.id
)
WHERE is_bot = 1;

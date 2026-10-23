-- SPDX-License-Identifier: AGPL-3.0-only
-- category_overwrites.target_id has no foreign key, so role deletes and
-- account deletions left rows behind that a category sync copied back into
-- channel_overwrites. Remove the existing orphans; the store now clears them.
DELETE FROM category_overwrites
WHERE target_type = 'role'
  AND target_id NOT IN (SELECT id FROM roles);

DELETE FROM category_overwrites
WHERE target_type = 'member'
  AND target_id NOT IN (SELECT id FROM users WHERE deleted_at IS NULL);

-- pinned_messages_on_delete runs on every message soft-delete and filters on
-- message_id alone, which the (channel_id, message_id) primary key cannot serve.
CREATE INDEX pinned_messages_message ON pinned_messages(message_id);

-- SPDX-License-Identifier: AGPL-3.0-only
-- One shared "Bots" role every bot holds; a bot keeps a managed role only while it is
-- granted permissions. See docs/decisions/0028-bot-accounts.md.
--
-- A partial unique index keeps the shared role a singleton, as is_everyone does.
ALTER TABLE roles ADD COLUMN is_bots_role INTEGER NOT NULL DEFAULT 0;

CREATE UNIQUE INDEX roles_bots_role ON roles(is_bots_role) WHERE is_bots_role = 1;

-- Only a deployment that has bots gets the role now; the first bot created elsewhere makes it.
INSERT INTO roles (id, name, permissions, is_everyone, created_at, is_bots_role)
SELECT randomblob(16), 'Bots', 0, 0, CAST(strftime('%s', 'now') AS INTEGER) * 1000, 1
WHERE EXISTS (SELECT 1 FROM bot_tokens);

-- Module principals have no bot_tokens row, so they are left out.
INSERT INTO member_roles (user_id, role_id)
SELECT u.id, r.id
FROM users u
JOIN roles r ON r.is_bots_role = 1
WHERE u.is_bot = 1
  AND u.deleted_at IS NULL
  AND EXISTS (SELECT 1 FROM bot_tokens t WHERE t.bot_user_id = u.id);

-- A managed role that grants nothing is now the Bots role's job.
DELETE FROM member_roles
WHERE role_id IN (SELECT id FROM roles WHERE managed_bot_id IS NOT NULL AND permissions = 0);
DELETE FROM channel_overwrites
WHERE target_type = 'role'
  AND target_id IN (SELECT id FROM roles WHERE managed_bot_id IS NOT NULL AND permissions = 0);
DELETE FROM category_overwrites
WHERE target_type = 'role'
  AND target_id IN (SELECT id FROM roles WHERE managed_bot_id IS NOT NULL AND permissions = 0);
DELETE FROM roles WHERE managed_bot_id IS NOT NULL AND permissions = 0;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The Space owner, the one member the role ladder exempts and nobody can act on.
-- It is the account that claimed the deployment, or, where that was never
-- recorded or the account is gone, the first human member who joined.
ALTER TABLE space_settings ADD COLUMN owner_id BLOB REFERENCES users(id) ON DELETE SET NULL;
UPDATE space_settings
   SET owner_id = COALESCE(
       (SELECT u.id FROM users u
         WHERE u.id = space_settings.setup_claimed_by
           AND u.deleted_at IS NULL AND u.is_bot = 0 AND u.is_webhook = 0
           AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
           AND NOT EXISTS (SELECT 1 FROM pending_members pm WHERE pm.user_id = u.id)),
       (SELECT u.id FROM users u
         WHERE u.deleted_at IS NULL AND u.is_bot = 0 AND u.is_webhook = 0
           AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
           AND NOT EXISTS (SELECT 1 FROM pending_members pm WHERE pm.user_id = u.id)
         ORDER BY u.created_at, u.id LIMIT 1))
 WHERE id = 1;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The Space owner, who holds every permission and whom nobody can act on.
-- It is the account that claimed the deployment, or, where that was never
-- recorded or the account is gone, the heir `store::space_owner::hand_on_owner`
-- would pick: the first human administrator who joined, else the first human.
-- The owner is never timed out, since nobody could lift it.
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
         ORDER BY
           CASE WHEN EXISTS (SELECT 1 FROM roles WHERE is_everyone = 1 AND (permissions & 1) != 0)
                  OR EXISTS (SELECT 1 FROM member_roles mr JOIN roles r ON r.id = mr.role_id
                             WHERE mr.user_id = u.id AND (r.permissions & 1) != 0)
                THEN 0 ELSE 1 END,
           u.created_at, u.id
         LIMIT 1))
 WHERE id = 1;
DELETE FROM member_timeouts
 WHERE user_id = (SELECT owner_id FROM space_settings WHERE id = 1);

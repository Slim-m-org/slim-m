-- SPDX-License-Identifier: AGPL-3.0-only
-- Who claimed the deployment and whether they finished or dismissed the
-- first-run setup. A deployment claimed before this column existed is marked
-- done, so an upgrade never opens a wizard over a space already in use.
ALTER TABLE space_settings ADD COLUMN setup_claimed_by BLOB REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE space_settings ADD COLUMN setup_done_at INTEGER;
UPDATE space_settings
   SET setup_done_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
 WHERE EXISTS (SELECT 1 FROM roles WHERE is_everyone = 1);

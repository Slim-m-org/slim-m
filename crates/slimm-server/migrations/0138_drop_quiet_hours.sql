-- SPDX-License-Identifier: AGPL-3.0-only
-- Drops the legacy quiet-hours window (migration 0056). Nothing has read it
-- since the notification schedule (migration 0081, decision 0033) replaced
-- it, and the `/push/quiet-hours` routes are gone.
ALTER TABLE users DROP COLUMN quiet_hours_start_minute;
ALTER TABLE users DROP COLUMN quiet_hours_end_minute;

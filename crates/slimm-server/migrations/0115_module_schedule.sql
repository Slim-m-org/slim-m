-- SPDX-License-Identifier: AGPL-3.0-only
-- The schedule capability (owner decision 2026-10-14): a module runs commands
-- on a timer with nobody invoking them and posts as itself.
-- schedules: the manifest's {command, every_minutes} list, recorded at install.
-- bot_user_id: the module's own is_bot principal, created when schedule is approved.
-- schedule_channel_id: where the admin lets its scheduled runs post.
-- module_schedule_runs: when each scheduled command last ran, so a restart
-- (main deploys continuously) does not reset a long interval.
ALTER TABLE installed_modules ADD COLUMN schedules TEXT NOT NULL DEFAULT '[]';
ALTER TABLE installed_modules ADD COLUMN bot_user_id BLOB REFERENCES users(id);
ALTER TABLE installed_modules ADD COLUMN schedule_channel_id BLOB REFERENCES channels(id);

CREATE TABLE module_schedule_runs (
    module_id   TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    command     TEXT NOT NULL,
    last_run_at INTEGER NOT NULL,
    PRIMARY KEY (module_id, command)
);

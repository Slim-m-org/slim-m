-- What each installed module's commands have done lately: one bounded row per
-- command, so an admin can see which module fails or burns time. The
-- cascade clears a module's row with the module.
CREATE TABLE module_run_stats (
    module_id        TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    command          TEXT NOT NULL,
    run_count        INTEGER NOT NULL DEFAULT 0,
    failure_count    INTEGER NOT NULL DEFAULT 0,
    last_run_at      INTEGER NOT NULL,
    last_ok_at       INTEGER,
    failing_since    INTEGER,
    last_error       TEXT CHECK (last_error IS NULL OR length(last_error) <= 300),
    last_error_at    INTEGER,
    last_duration_ms INTEGER NOT NULL DEFAULT 0,
    max_duration_ms  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (module_id, command)
) STRICT;

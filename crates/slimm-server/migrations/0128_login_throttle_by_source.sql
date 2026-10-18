-- The password guess throttle now counts per (account, caller address key), so a stranger's
-- guesses never keep the real owner out. The rows are short-lived backoff state, so the old
-- per-account table is dropped rather than migrated.
DROP TABLE login_throttle;
CREATE TABLE login_throttle (
    user_id         BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source          TEXT NOT NULL,
    failures        INTEGER NOT NULL,
    last_failure_at INTEGER NOT NULL,
    locked_until    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, source)
) STRICT;

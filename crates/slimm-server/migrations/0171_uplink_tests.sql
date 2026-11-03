-- Uplink measurements an admin ran from the voice settings: how fast this
-- host can send, kept so a change over time shows. Pruned in code to the last few.
CREATE TABLE uplink_tests (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    measured_at INTEGER NOT NULL,
    mbit_per_s  REAL    NOT NULL,
    bytes       INTEGER NOT NULL,
    duration_ms INTEGER NOT NULL
) STRICT;

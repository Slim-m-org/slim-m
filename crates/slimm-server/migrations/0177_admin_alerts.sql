-- Operator alerts for people who hold MANAGE_SERVER: one row per condition
-- (kind plus an optional subject such as a module id), open until it recovers.
-- notified_at is when a push last went out for the condition, which is what
-- the one-per-kind-per-window rate limit reads; announced says the current
-- opening was pushed, which is what earns a recovery push.
CREATE TABLE admin_alerts (
    kind        TEXT    NOT NULL,
    subject     TEXT    NOT NULL DEFAULT '',
    detail      TEXT    NOT NULL,
    raised_at   INTEGER NOT NULL,
    resolved_at INTEGER,
    notified_at INTEGER,
    announced   INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (kind, subject)
) STRICT;

-- One admin's choice to stop hearing about these; the list in Storage still shows them.
ALTER TABLE users ADD COLUMN admin_alerts_muted INTEGER NOT NULL DEFAULT 0;

-- The last rebuild of moderation_audit_log for a new action (issue 1832).
--
-- Seven migrations (0049, 0077, 0078, 0086, 0092, 0094, 0098) rebuilt this
-- table only to widen the action CHECK, because SQLite cannot alter a CHECK in
-- place. The list now lives in Rust (store::moderation_audit::ModerationAction,
-- the only writer), so the table keeps just a shape check and a new action
-- needs no migration. The until rule stays: it constrains the two timeout
-- actions, which already exist.
--
-- Copied from 0098's template: same columns and ids, all three indexes
-- recreated, no PRAGMA foreign_keys = OFF since no table references this one,
-- and the table has no triggers.
CREATE TABLE moderation_audit_log_new (
    id         INTEGER PRIMARY KEY,
    actor_id   BLOB REFERENCES users(id) ON DELETE SET NULL,
    subject_id BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action     TEXT NOT NULL,
    reason     TEXT,
    until      INTEGER,
    created_at INTEGER NOT NULL,
    CONSTRAINT moderation_audit_action
        CHECK (length(action) BETWEEN 1 AND 64 AND action NOT GLOB '*[^a-z0-9_]*'),
    CONSTRAINT moderation_audit_until CHECK (
        CASE action
            WHEN 'timeout' THEN until IS NOT NULL
            WHEN 'timeout_cleared' THEN 1
            ELSE until IS NULL
        END
    )
) STRICT;

INSERT INTO moderation_audit_log_new
    (id, actor_id, subject_id, action, reason, until, created_at)
SELECT id, actor_id, subject_id, action, reason, until, created_at
FROM moderation_audit_log;

DROP TABLE moderation_audit_log;
ALTER TABLE moderation_audit_log_new RENAME TO moderation_audit_log;

CREATE INDEX moderation_audit_log_subject ON moderation_audit_log(subject_id, created_at);
CREATE INDEX moderation_audit_log_actor ON moderation_audit_log(actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX moderation_audit_log_created_at
    ON moderation_audit_log(created_at DESC, id DESC);

-- Every admin change to the space: settings, roles, channels, categories,
-- permissions, invites, emoji and modules. Member moderation keeps its own
-- moderation_audit_log, whose subject is always a member.
--
-- Written by one HTTP middleware (http/admin_audit.rs) after a write succeeds,
-- so the action is the route that ran and target_id is that route's id, kept
-- as text because module and source ids are not UUIDs. detail is a small JSON
-- object: the changed field names, the name a create or rename set, and any
-- other path ids. It never holds field values beyond that name. The feed
-- pages by id, the rowid, so it needs no index of its own.
CREATE TABLE admin_audit_log (
    id         INTEGER PRIMARY KEY,
    actor_id   BLOB REFERENCES users(id) ON DELETE SET NULL,
    action     TEXT NOT NULL,
    target_id  TEXT,
    detail     TEXT NOT NULL DEFAULT '{}',
    created_at INTEGER NOT NULL,
    CONSTRAINT admin_audit_action
        CHECK (length(action) BETWEEN 1 AND 64 AND action NOT GLOB '*[^a-z0-9_.]*'),
    CONSTRAINT admin_audit_target CHECK (target_id IS NULL OR length(target_id) <= 128),
    CONSTRAINT admin_audit_detail CHECK (json_valid(detail) AND length(detail) <= 4096)
) STRICT;


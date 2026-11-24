-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Account deletion seeks these rather than scanning tables that grow with use.
CREATE INDEX voice_call_events_user ON voice_call_events(user_id);
CREATE INDEX voice_sessions_user ON voice_sessions(user_id);
CREATE INDEX poll_votes_user ON poll_votes(user_id);
CREATE INDEX call_records_caller ON call_records(caller_id) WHERE caller_id IS NOT NULL;
CREATE INDEX admin_audit_log_actor ON admin_audit_log(actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX call_transcripts_started_by ON call_transcripts(started_by)
    WHERE started_by IS NOT NULL;

-- Who wrote what, kept only for content whose deleted author somebody still
-- blocks, so that block keeps hiding it. Everyone else sees no author.
CREATE TABLE blocked_author_messages (
    message_id BLOB NOT NULL PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    author_id  BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX blocked_author_messages_author ON blocked_author_messages(author_id);

CREATE TABLE blocked_author_canvas_objects (
    object_id BLOB NOT NULL PRIMARY KEY REFERENCES canvas_objects(id) ON DELETE CASCADE,
    author_id BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;
CREATE INDEX blocked_author_canvas_objects_author ON blocked_author_canvas_objects(author_id);

-- A deletion runs in bounded steps after the account is closed; a row here is
-- one that has not finished, so a restart can complete it.
CREATE TABLE account_purges (
    user_id    BLOB NOT NULL PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    started_at INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

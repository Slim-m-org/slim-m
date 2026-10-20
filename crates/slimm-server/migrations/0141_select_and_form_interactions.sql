-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A select choice and a form submission are interactions of their own kind
-- (decision 0083), and a form a bot opened is kept on the press it answered so
-- the submission can be checked against it. Interactions live a quarter of an
-- hour, so the table is rebuilt in place and the rows it holds are kept: SQLite
-- cannot widen a CHECK constraint any other way. A press also remembers the one
-- submission it accepted, so a form is delivered to its bot at most once.
CREATE TABLE interactions_new (
    id BLOB PRIMARY KEY,
    bot_id BLOB NOT NULL,
    clicker_id BLOB NOT NULL,
    channel_id BLOB NOT NULL,
    message_id BLOB,
    custom_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    answered_at INTEGER,
    kind TEXT NOT NULL DEFAULT 'button'
        CHECK (kind IN ('button', 'message_menu', 'call_control', 'select', 'form_submit')),
    option_id TEXT,
    form TEXT,
    submitted_id BLOB,
    submitted_fields TEXT
) STRICT, WITHOUT ROWID;

INSERT INTO interactions_new
    (id, bot_id, clicker_id, channel_id, message_id, custom_id, created_at, answered_at, kind,
     option_id)
SELECT id, bot_id, clicker_id, channel_id, message_id, custom_id, created_at, answered_at, kind,
       option_id
FROM interactions;

DROP TABLE interactions;
ALTER TABLE interactions_new RENAME TO interactions;
CREATE INDEX interactions_created_at ON interactions(created_at);

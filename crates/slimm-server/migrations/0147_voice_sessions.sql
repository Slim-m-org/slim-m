-- SPDX-License-Identifier: AGPL-3.0-only
-- One row per member per call (decision 0091): opened by the LiveKit join
-- webhook, closed by its leave, a finished room, a stale heartbeat or a
-- restart, so a missed leave still ends the session. Times are milliseconds.
-- alone_ms is how long the member was the only one in the room. Closed rows
-- age out after 90 days and go with the member on account deletion.
CREATE TABLE voice_sessions (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    sid        TEXT NOT NULL,
    joined_at  INTEGER NOT NULL,
    left_at    INTEGER,
    alone_ms   INTEGER NOT NULL DEFAULT 0,
    closed_seq INTEGER
) STRICT;

CREATE UNIQUE INDEX voice_sessions_closed_seq ON voice_sessions(closed_seq) WHERE closed_seq IS NOT NULL;

CREATE TABLE voice_session_close_seq (
    id   INTEGER PRIMARY KEY CHECK (id = 1),
    last INTEGER NOT NULL
) STRICT;
INSERT INTO voice_session_close_seq (id, last) VALUES (1, 0);
CREATE INDEX voice_sessions_closed_at ON voice_sessions(left_at) WHERE left_at IS NOT NULL;
CREATE INDEX voice_sessions_open_sid ON voice_sessions(user_id, sid) WHERE left_at IS NULL;
CREATE INDEX voice_sessions_channel ON voice_sessions(channel_id, joined_at);

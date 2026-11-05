-- SPDX-License-Identifier: AGPL-3.0-only
-- A member's opt-in to hear when a voice channel's call starts, someone joins,
-- or someone starts streaming (docs/decisions/0107). Absence of a row means
-- off; a row is only kept while at least one of its choices is on.
CREATE TABLE voice_notify_prefs (
    user_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    joins      TEXT NOT NULL CHECK (joins IN ('off', 'first', 'every')),
    streams    INTEGER NOT NULL CHECK (streams IN (0, 1)),
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, channel_id)
) STRICT, WITHOUT ROWID;

-- The fan-out reads one channel's opted-in members, the opposite lead to the key.
CREATE INDEX voice_notify_prefs_channel ON voice_notify_prefs(channel_id);

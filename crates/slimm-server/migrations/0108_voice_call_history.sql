-- SPDX-License-Identifier: AGPL-3.0-only
-- A voice channel's call history (decision 0066): the joins, leaves and
-- screen shares the LiveKit webhook reports, each stamped when it arrived.
-- Calls are worked out from these when read. Nothing about audio or
-- speaking is kept, and rows age out after 30 days.
CREATE TABLE voice_call_events (
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    at         INTEGER NOT NULL,
    user_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK (kind IN ('joined', 'left', 'share_started', 'share_stopped'))
) STRICT;

CREATE INDEX voice_call_events_channel ON voice_call_events(channel_id, at);
CREATE INDEX voice_call_events_at ON voice_call_events(at);

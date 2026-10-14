-- SPDX-License-Identifier: AGPL-3.0-only
-- Temporary voice rooms (decision 0065): a lobby voice channel makes a room
-- per person, the room records its owner and lobby, and any voice channel
-- can cap how many people join. Every existing channel keeps today's
-- behaviour: no lobby, no room, no limit.
ALTER TABLE channels ADD COLUMN creates_rooms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channels ADD COLUMN user_limit INTEGER NOT NULL DEFAULT 0;
ALTER TABLE channels ADD COLUMN room_owner_id BLOB REFERENCES users(id) ON DELETE SET NULL;
ALTER TABLE channels ADD COLUMN room_lobby_id BLOB REFERENCES channels(id) ON DELETE SET NULL;
ALTER TABLE channels ADD COLUMN room_locked INTEGER NOT NULL DEFAULT 0;
CREATE INDEX idx_channels_room_owner ON channels(room_lobby_id, room_owner_id)
    WHERE room_owner_id IS NOT NULL;

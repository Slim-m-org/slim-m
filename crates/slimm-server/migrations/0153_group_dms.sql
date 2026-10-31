-- SPDX-License-Identifier: AGPL-3.0-only
-- Group DMs (docs/decisions/0095): a DM channel with 3 to 8 participants.
-- A pair stays in dm_channels; a group has no unique key there because any
-- number of groups may share the same members. The roster lives here and
-- membership is the only thing that grants access, as it is for a pair.
CREATE TABLE group_dm_members (
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    user_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    added_by   BLOB REFERENCES users(id) ON DELETE SET NULL,
    joined_at  INTEGER NOT NULL,
    PRIMARY KEY (channel_id, user_id)
) STRICT, WITHOUT ROWID;

-- The DM list reads "every group this user is in".
CREATE INDEX group_dm_members_user ON group_dm_members(user_id, channel_id);

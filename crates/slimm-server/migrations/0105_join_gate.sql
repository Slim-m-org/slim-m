-- SPDX-License-Identifier: AGPL-3.0-only
-- The join gate: with it on, a new member waits in pending_members, able to
-- read only the rules channel, until they accept the rules. joins_paused is
-- raid mode, which refuses every new member, invite or not.
ALTER TABLE space_settings ADD COLUMN join_gate INTEGER NOT NULL DEFAULT 0;
ALTER TABLE space_settings ADD COLUMN rules_text TEXT NOT NULL DEFAULT '';
ALTER TABLE space_settings ADD COLUMN rules_channel_id BLOB REFERENCES channels(id) ON DELETE SET NULL;
ALTER TABLE space_settings ADD COLUMN joins_paused INTEGER NOT NULL DEFAULT 0;

CREATE TABLE pending_members (
    user_id BLOB PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    since   INTEGER NOT NULL
) STRICT;

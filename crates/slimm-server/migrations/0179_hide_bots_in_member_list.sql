-- SPDX-License-Identifier: AGPL-3.0-only
-- Whether the member list leaves bots out, for everyone. Off, the default every
-- deployment keeps on upgrade, lists them in their own section as before.
ALTER TABLE space_settings ADD COLUMN hide_bots_in_member_list INTEGER NOT NULL DEFAULT 0
    CHECK (hide_bots_in_member_list IN (0, 1));

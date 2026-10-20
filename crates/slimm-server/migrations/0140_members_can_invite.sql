-- SPDX-License-Identifier: AGPL-3.0-only
-- Whether any member may create invites, with the short expiry and use cap
-- the invite routes enforce on them. Off, the default every deployment keeps
-- on upgrade, leaves invites to accounts holding CREATE_INVITE.
ALTER TABLE space_settings ADD COLUMN members_can_invite INTEGER NOT NULL DEFAULT 0
    CHECK (members_can_invite IN (0, 1));

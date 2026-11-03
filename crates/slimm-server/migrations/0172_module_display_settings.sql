-- SPDX-License-Identifier: AGPL-3.0-only
-- Where module output shows for everyone: badges beside names in the member list
-- (off, since they compete with the role chip) and module sections on profile cards
-- (on, which is what profile cards have always done).
ALTER TABLE space_settings ADD COLUMN module_member_badges INTEGER NOT NULL DEFAULT 0
    CHECK (module_member_badges IN (0, 1));
ALTER TABLE space_settings ADD COLUMN module_profile_sections INTEGER NOT NULL DEFAULT 1
    CHECK (module_profile_sections IN (0, 1));

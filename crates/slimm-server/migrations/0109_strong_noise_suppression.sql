-- SPDX-License-Identifier: AGPL-3.0-only
-- Whether members' microphones use the stronger rnnoise suppression by
-- default. It runs on each member's own device and a member can still pick
-- either mode in Voice settings; this only decides what "Space default"
-- means. Off, the default every deployment keeps on upgrade.
ALTER TABLE space_settings ADD COLUMN strong_noise_suppression INTEGER NOT NULL DEFAULT 0
    CHECK (strong_noise_suppression IN (0, 1));

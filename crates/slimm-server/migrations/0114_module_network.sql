-- SPDX-License-Identifier: AGPL-3.0-only
-- The net.fetch capability (owner decision 2026-10-14): the hosts a module's
-- manifest listed when an admin approved it, and whether that admin also gave
-- the separate second approval for local network addresses. Both are written
-- by the Dock install alongside approved_host_capabilities.
ALTER TABLE installed_modules ADD COLUMN network_hosts TEXT NOT NULL DEFAULT '[]';
ALTER TABLE installed_modules ADD COLUMN local_network_approved INTEGER NOT NULL DEFAULT 0
    CHECK (local_network_approved IN (0, 1));

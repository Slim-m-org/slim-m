-- SPDX-License-Identifier: AGPL-3.0-only
-- The starter soundboard clips this Space has been offered (decision 0118).
--
-- One row per bundled clip, written whether or not the clip was added, so a
-- starter clip an admin deleted stays deleted and a later release can still
-- offer a clip it adds to the set.
CREATE TABLE soundboard_starter_offered (
    key        TEXT PRIMARY KEY,
    offered_at INTEGER NOT NULL
) STRICT;

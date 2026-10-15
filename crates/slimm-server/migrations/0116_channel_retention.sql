-- SPDX-License-Identifier: AGPL-3.0-only
-- A channel's own message retention, overriding the Space's window. No row
-- means the channel follows the Space; 0 keeps it forever. A side table so
-- the many queries that select channel rows need not carry it.
CREATE TABLE channel_retention (
    channel_id     BLOB PRIMARY KEY REFERENCES channels(id) ON DELETE CASCADE,
    retention_days INTEGER NOT NULL CHECK (retention_days >= 0),
    updated_at     INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

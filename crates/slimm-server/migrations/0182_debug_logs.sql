-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A client debug log a member chose to send to the admins. The text is already
-- scrubbed by the client and capped by the route; rows expire by age and by
-- count per member, and go with the account.
CREATE TABLE debug_logs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    note        TEXT NOT NULL DEFAULT '' CHECK (length(note) <= 1000),
    app_version TEXT NOT NULL CHECK (length(app_version) <= 64),
    platform    TEXT NOT NULL CHECK (length(platform) <= 64),
    log         TEXT NOT NULL,
    size_bytes  INTEGER NOT NULL CHECK (size_bytes >= 0),
    created_at  INTEGER NOT NULL
) STRICT;
CREATE INDEX debug_logs_user_idx ON debug_logs (user_id, id);
CREATE INDEX debug_logs_created_idx ON debug_logs (created_at);

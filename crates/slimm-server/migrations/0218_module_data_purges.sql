-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A deleted member's module data still to be purged. A row is written when the
-- account is closed and dropped once every module reports success, so a busy
-- module is retried by a sweep instead of keeping the member's rows forever.
CREATE TABLE module_data_purges (
    user_id    BLOB NOT NULL PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    started_at INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

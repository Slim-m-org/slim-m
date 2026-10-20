-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A member's data export and an administrator's space export are background
-- jobs that write one archive to disk. The row is the job's status; the file
-- is named after its id and removed when the row expires or the account goes.
CREATE TABLE data_exports (
    id          BLOB PRIMARY KEY,
    user_id     BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL CHECK (kind IN ('member', 'space')),
    status      TEXT NOT NULL CHECK (status IN ('queued', 'running', 'ready', 'failed', 'expired')),
    processed   INTEGER NOT NULL DEFAULT 0 CHECK (processed >= 0),
    total       INTEGER NOT NULL DEFAULT 0 CHECK (total >= 0),
    size_bytes  INTEGER CHECK (size_bytes IS NULL OR size_bytes >= 0),
    error       TEXT,
    created_at  INTEGER NOT NULL,
    finished_at INTEGER,
    expires_at  INTEGER
) STRICT, WITHOUT ROWID;

CREATE INDEX data_exports_by_user ON data_exports (user_id, created_at DESC);

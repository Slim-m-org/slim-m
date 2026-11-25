-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Which export made a canvas channel (decision 0139), so a retry with the same id replays that export and never clears a source it did not copy.
CREATE TABLE canvas_exports (
    channel_id        BLOB PRIMARY KEY REFERENCES channels(id),
    source_channel_id BLOB NOT NULL REFERENCES channels(id),
    clear_source      INTEGER NOT NULL CHECK (clear_source IN (0, 1)),
    clear_op_id       BLOB,
    copied            INTEGER NOT NULL,
    skipped           INTEGER NOT NULL,
    cleared           INTEGER NOT NULL,
    spared            INTEGER NOT NULL,
    created_at        INTEGER NOT NULL
) STRICT;

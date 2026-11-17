-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A picture a viewer stamped on someone's shared screen (decision 0121): the
-- sharer and the call may fetch it, the sharer may report it, and the sweep
-- removes it 24 hours on unless an open report holds it.
CREATE TABLE screen_stamps (
    id         BLOB PRIMARY KEY,
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    sender_id  BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_id  BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256     BLOB NOT NULL REFERENCES attachments(sha256) ON DELETE RESTRICT,
    report_id  BLOB REFERENCES reports(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL
) STRICT;

CREATE INDEX screen_stamps_by_target ON screen_stamps(target_id, created_at);
CREATE INDEX screen_stamps_by_sha ON screen_stamps(sha256);
CREATE INDEX screen_stamps_by_created ON screen_stamps(created_at);
CREATE INDEX screen_stamps_by_report ON screen_stamps(report_id) WHERE report_id IS NOT NULL;

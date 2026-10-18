-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A channel's default notification level, applied to members with no
-- notification choice of their own for it. 'everything' (what every existing
-- channel keeps) means no default: members follow their account preference.
ALTER TABLE channels ADD COLUMN default_notification TEXT NOT NULL DEFAULT 'everything'
    CHECK (default_notification IN ('everything', 'mentions', 'nothing'));

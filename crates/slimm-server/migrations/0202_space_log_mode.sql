-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- How much the server logs, set by an admin and applied without a restart
-- (decision 0129). `off` is the operator's own SLIMM_LOG filter unchanged.
ALTER TABLE space_settings ADD COLUMN log_mode TEXT NOT NULL DEFAULT 'off'
    CHECK (log_mode IN ('off', 'compact', 'verbose'));

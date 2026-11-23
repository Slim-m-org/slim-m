-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A connector (decision 0090): an installed module whose logic is an external
-- program holding a bot token, not a WASM artifact. `provider` says which.
--
-- `connector_permissions` is the bitmask the admin approved at install. It is
-- the ceiling on everything the module's principal (`bot_user_id`) may do,
-- whatever roles it comes to hold later, and while the module is disabled the
-- ceiling is zero. NULL for a WASM module, whose principal is not capped.
ALTER TABLE installed_modules ADD COLUMN provider TEXT NOT NULL DEFAULT 'wasm'
    CHECK (provider IN ('wasm', 'connector'));
ALTER TABLE installed_modules ADD COLUMN connector_permissions INTEGER
    CHECK (connector_permissions IS NULL OR provider = 'connector');

-- Every permission check looks the principal up here, so it must not scan.
CREATE INDEX installed_modules_bot_user ON installed_modules(bot_user_id);

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Removing a device or deleting an account cascades its refresh tokens away, so
-- a later refresh with one looked like a token this server never issued. This
-- keeps the hash and why it went, until the token would have been swept anyway.
CREATE TABLE dropped_refresh_tokens (
    token_hash TEXT PRIMARY KEY,
    cause      TEXT NOT NULL CHECK (cause IN ('device_removed', 'account_deleted')),
    expires_at INTEGER NOT NULL
) STRICT;
CREATE INDEX dropped_refresh_tokens_expiry ON dropped_refresh_tokens(expires_at);

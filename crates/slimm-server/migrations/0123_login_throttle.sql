-- SPDX-License-Identifier: AGPL-3.0-only
-- Per-account password guess throttle, beside the per-address limiter and the TOTP lockout.
--
-- One row per account that has recently failed a password check. `locked_until` is a bounded
-- backoff, never a permanent lock, and the row is deleted on a successful sign-in.
CREATE TABLE login_throttle (
    user_id         BLOB PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    failures        INTEGER NOT NULL,
    last_failure_at INTEGER NOT NULL,
    locked_until    INTEGER NOT NULL DEFAULT 0
) STRICT;

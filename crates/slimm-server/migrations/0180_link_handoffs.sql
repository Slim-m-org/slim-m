-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A Discord identity the callback has read, held until the app of the member
-- who started the link finishes it. The callback cannot tell who approved in the
-- browser, so it links nothing: it stores the identity under a fresh secret
-- (only its hash is kept) that the starter never saw, and the app completes the
-- link with its own bearer. Rows are spent on use and expire like link_states.
CREATE TABLE link_handoffs (
    handoff_hash TEXT PRIMARY KEY CHECK (length(handoff_hash) BETWEEN 32 AND 128),
    user_id      BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider     TEXT NOT NULL CHECK (provider IN ('discord')),
    external_id  TEXT NOT NULL CHECK (length(external_id) BETWEEN 1 AND 64),
    username     TEXT NOT NULL CHECK (length(username) BETWEEN 1 AND 64),
    display_name TEXT CHECK (display_name IS NULL OR length(display_name) <= 64),
    avatar_hash  TEXT CHECK (avatar_hash IS NULL OR length(avatar_hash) <= 64),
    expires_at   INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

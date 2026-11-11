-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Steam as a second linked provider (decision 0115). The provider CHECKs name
-- the allowed providers, and SQLite cannot alter a CHECK, so the three link
-- tables are rebuilt. share_activity is the member's opt-in to showing what
-- they play; the poller reads only links where it is 1.
CREATE TABLE linked_accounts_v2 (
    user_id           BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider          TEXT NOT NULL CHECK (provider IN ('discord', 'steam')),
    external_id       TEXT NOT NULL CHECK (length(external_id) BETWEEN 1 AND 64),
    username          TEXT NOT NULL CHECK (length(username) BETWEEN 1 AND 64),
    display_name      TEXT CHECK (display_name IS NULL OR length(display_name) <= 64),
    linked_at         INTEGER NOT NULL,
    avatar_updated_at INTEGER,
    share_activity    INTEGER NOT NULL DEFAULT 0 CHECK (share_activity IN (0, 1)),
    PRIMARY KEY (user_id, provider),
    UNIQUE (provider, external_id)
) STRICT, WITHOUT ROWID;
INSERT INTO linked_accounts_v2
    (user_id, provider, external_id, username, display_name, linked_at, avatar_updated_at)
SELECT user_id, provider, external_id, username, display_name, linked_at, avatar_updated_at
FROM linked_accounts;
DROP TABLE linked_accounts;
ALTER TABLE linked_accounts_v2 RENAME TO linked_accounts;

CREATE TABLE link_states_v2 (
    state      TEXT PRIMARY KEY CHECK (length(state) BETWEEN 32 AND 128),
    user_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider   TEXT NOT NULL CHECK (provider IN ('discord', 'steam')),
    expires_at INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
INSERT INTO link_states_v2 SELECT state, user_id, provider, expires_at FROM link_states;
DROP TABLE link_states;
ALTER TABLE link_states_v2 RENAME TO link_states;

CREATE TABLE link_handoffs_v2 (
    handoff_hash TEXT PRIMARY KEY CHECK (length(handoff_hash) BETWEEN 32 AND 128),
    user_id      BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider     TEXT NOT NULL CHECK (provider IN ('discord', 'steam')),
    external_id  TEXT NOT NULL CHECK (length(external_id) BETWEEN 1 AND 64),
    username     TEXT NOT NULL CHECK (length(username) BETWEEN 1 AND 64),
    display_name TEXT CHECK (display_name IS NULL OR length(display_name) <= 64),
    avatar_hash  TEXT CHECK (avatar_hash IS NULL OR length(avatar_hash) <= 64),
    expires_at   INTEGER NOT NULL
) STRICT, WITHOUT ROWID;
INSERT INTO link_handoffs_v2
SELECT handoff_hash, user_id, provider, external_id, username, display_name, avatar_hash, expires_at
FROM link_handoffs;
DROP TABLE link_handoffs;
ALTER TABLE link_handoffs_v2 RENAME TO link_handoffs;

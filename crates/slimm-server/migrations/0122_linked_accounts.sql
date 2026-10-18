-- Accounts a member has linked from elsewhere, shown on their profile.
-- Discord is the only provider; the CHECK names it so a new one is a
-- deliberate migration. external_id is unique per provider, so one Discord
-- account links to one member.
CREATE TABLE linked_accounts (
    user_id      BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider     TEXT NOT NULL CHECK (provider IN ('discord')),
    external_id  TEXT NOT NULL CHECK (length(external_id) BETWEEN 1 AND 64),
    username     TEXT NOT NULL CHECK (length(username) BETWEEN 1 AND 64),
    display_name TEXT CHECK (display_name IS NULL OR length(display_name) <= 64),
    linked_at    INTEGER NOT NULL,
    PRIMARY KEY (user_id, provider),
    UNIQUE (provider, external_id)
) STRICT, WITHOUT ROWID;

-- One pending link per state value: minted by /start, spent by the callback,
-- and only valid until expires_at, which is what stops a forged callback.
CREATE TABLE link_states (
    state      TEXT PRIMARY KEY CHECK (length(state) BETWEEN 32 AND 128),
    user_id    BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider   TEXT NOT NULL CHECK (provider IN ('discord')),
    expires_at INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

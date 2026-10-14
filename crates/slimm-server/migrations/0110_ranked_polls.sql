-- SPDX-License-Identifier: AGPL-3.0-only
-- Ranked-choice polls. A ranked poll keeps one poll_votes row per voter,
-- holding their first choice, so first-preference tallies and every read
-- that already counts poll_votes stay correct unchanged; the full order
-- lives here, one row per ranked option. The instant-runoff result is
-- computed from these rows on read, never stored.
--
-- Each rank row hangs off the voter's poll_votes row, so clearing a vote
-- (or the account purge deleting it) takes the ranking with it.
ALTER TABLE polls ADD COLUMN ranked INTEGER NOT NULL DEFAULT 0 CHECK (ranked IN (0, 1));

CREATE TABLE poll_rankings (
    message_id BLOB NOT NULL,
    user_id    BLOB NOT NULL,
    rank       INTEGER NOT NULL CHECK (rank >= 0),
    position   INTEGER NOT NULL,
    PRIMARY KEY (message_id, user_id, rank),
    UNIQUE (message_id, user_id, position),
    FOREIGN KEY (message_id, user_id) REFERENCES poll_votes(message_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (message_id, position) REFERENCES poll_options(message_id, position) ON DELETE CASCADE
) STRICT, WITHOUT ROWID;

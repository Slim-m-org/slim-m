-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- One person's ordered favorites: GIFs and media they kept from messages.
--
-- Private to the account, like `saved_messages` (0060), and a separate table
-- for the same reason: nobody else can read, add to, or count it. Unlike a
-- save it is ordered by the owner (`position`, lowest first) and holds two
-- kinds of entry in one list, because the picker shows them as one grid.
--
-- A `gif` entry keeps the provider's two CDN URLs and title, captured from
-- the search cache when it was favorited. The search token is short-lived and
-- a favorite has to outlive it. The URLs never leave the server: a client only
-- ever sees the favorite id and reaches the image through the preview and
-- select routes.
--
-- An `attachment` entry keeps only a reference: the attachment's content hash
-- and the message it was seen on. No bytes are copied and no row is added to
-- `attachments`, so a favorite never keeps a file alive. `message_id` is SET
-- NULL rather than cascaded so that losing the message leaves an entry the
-- owner can see is unavailable and remove, instead of one that vanishes.
CREATE TABLE user_favorites (
    id                BLOB NOT NULL PRIMARY KEY,
    user_id           BLOB NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind              TEXT NOT NULL CHECK (kind IN ('gif', 'attachment')),
    position          INTEGER NOT NULL,
    created_at        INTEGER NOT NULL,
    title             TEXT NOT NULL DEFAULT '',
    width             INTEGER NOT NULL DEFAULT 0,
    height            INTEGER NOT NULL DEFAULT 0,
    gif_preview_url   TEXT,
    gif_full_url      TEXT,
    attachment_sha256 BLOB,
    content_type      TEXT,
    message_id        BLOB REFERENCES messages(id) ON DELETE SET NULL
) STRICT;

CREATE INDEX user_favorites_by_user ON user_favorites(user_id, position);

-- Favoriting the same GIF or the same file twice keeps one entry.
CREATE UNIQUE INDEX user_favorites_gif_once
    ON user_favorites(user_id, gif_full_url) WHERE kind = 'gif';
CREATE UNIQUE INDEX user_favorites_attachment_once
    ON user_favorites(user_id, attachment_sha256) WHERE kind = 'attachment';

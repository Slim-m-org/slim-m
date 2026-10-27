-- Two side tables, neither a column on `messages` (every one of that table's
-- SELECTs would then carry them).
--
-- `message_link_preview_suppressions`: a message whose link-preview cards were
-- removed by its author or a moderator. Absence of a row means previews show.
-- The row stays for everyone, and the cascade drops it with the message.
CREATE TABLE message_link_preview_suppressions (
    message_id    BLOB PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    suppressed_at INTEGER NOT NULL
) STRICT;

-- `attachment_text`: one row per attachment blob whose text was extracted (or
-- tried and found empty), so the background pass never repeats it. The text
-- itself lives only in `attachment_text_fts`, keyed by `fts_rowid`; the
-- attachments table is content-addressed, so one extraction serves every
-- message that carries the same bytes.
CREATE TABLE attachment_text (
    fts_rowid    INTEGER PRIMARY KEY,
    sha256       BLOB NOT NULL UNIQUE REFERENCES attachments(sha256) ON DELETE CASCADE,
    extracted_at INTEGER NOT NULL
) STRICT;

CREATE VIRTUAL TABLE attachment_text_fts USING fts5(
    content,
    tokenize='unicode61'
);

-- A cascade from `attachments` fires this too, so the index never outlives its row.
CREATE TRIGGER attachment_text_ad AFTER DELETE ON attachment_text BEGIN
    DELETE FROM attachment_text_fts WHERE rowid = OLD.fts_rowid;
END;

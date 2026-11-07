-- Attachment file names, searchable beside message content and extracted
-- text, so a message that is only a file is found by what the file is called.
-- `attachment_name_index` maps each message attachment to its row in
-- `attachment_name_fts`; message_attachments is WITHOUT ROWID, so the FTS
-- rowid cannot be borrowed from it. The name indexed is the one the message
-- shows: its own, else the upload's.
CREATE TABLE attachment_name_index (
    fts_rowid  INTEGER PRIMARY KEY,
    message_id BLOB NOT NULL,
    sha256     BLOB NOT NULL,
    UNIQUE (message_id, sha256),
    FOREIGN KEY (message_id, sha256)
        REFERENCES message_attachments(message_id, sha256) ON DELETE CASCADE
) STRICT;

CREATE VIRTUAL TABLE attachment_name_fts USING fts5(
    name,
    tokenize='unicode61'
);

CREATE TRIGGER attachment_name_index_ad AFTER DELETE ON attachment_name_index BEGIN
    DELETE FROM attachment_name_fts WHERE rowid = OLD.fts_rowid;
END;

CREATE TRIGGER message_attachments_name_ai AFTER INSERT ON message_attachments BEGIN
    INSERT INTO attachment_name_index (message_id, sha256) VALUES (NEW.message_id, NEW.sha256);
    INSERT INTO attachment_name_fts (rowid, name)
    SELECT last_insert_rowid(),
           COALESCE(NEW.filename, (SELECT filename FROM attachments WHERE sha256 = NEW.sha256), '');
END;

CREATE TRIGGER message_attachments_name_au AFTER UPDATE OF filename ON message_attachments BEGIN
    UPDATE attachment_name_fts
    SET name = COALESCE(NEW.filename, (SELECT filename FROM attachments WHERE sha256 = NEW.sha256), '')
    WHERE rowid = (SELECT fts_rowid FROM attachment_name_index
                   WHERE message_id = NEW.message_id AND sha256 = NEW.sha256);
END;

CREATE TRIGGER message_attachments_name_ad AFTER DELETE ON message_attachments BEGIN
    DELETE FROM attachment_name_index WHERE message_id = OLD.message_id AND sha256 = OLD.sha256;
END;

INSERT INTO attachment_name_index (message_id, sha256)
SELECT message_id, sha256 FROM message_attachments;

INSERT INTO attachment_name_fts (rowid, name)
SELECT i.fts_rowid, COALESCE(ma.filename, a.filename, '')
FROM attachment_name_index i
JOIN message_attachments ma ON ma.message_id = i.message_id AND ma.sha256 = i.sha256
LEFT JOIN attachments a ON a.sha256 = ma.sha256;

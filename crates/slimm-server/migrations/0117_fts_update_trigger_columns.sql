-- messages_fts_au fired on every UPDATE of messages, so nulling author_id on
-- account deletion, a soft delete, or an edited_at touch rewrote the FTS row
-- for nothing (issue 2060). It now fires only when a column its body reads
-- changes; the body is unchanged.
DROP TRIGGER messages_fts_au;

CREATE TRIGGER messages_fts_au AFTER UPDATE OF content, is_encrypted, fts_rowid ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content)
        SELECT 'delete', OLD.fts_rowid, OLD.content WHERE OLD.is_encrypted = 0;
    INSERT INTO messages_fts(rowid, content)
        SELECT NEW.fts_rowid, NEW.content WHERE NEW.is_encrypted = 0;
END;

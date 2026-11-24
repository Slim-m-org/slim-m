-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Two gaps in message search. A language written without spaces (Chinese,
-- Japanese kana, Thai, Lao, Khmer, Myanmar) is one unicode61 token, so a word inside a sentence
-- never matched; a trigram index over just those messages finds it. And text
-- a message carries outside `content` (a forward's snapshot, a poll's question
-- and options, an embed's title, description and fields) was never indexed.

CREATE VIRTUAL TABLE message_trigram_fts USING fts5(content, tokenize = 'trigram');

CREATE TRIGGER message_trigram_ai AFTER INSERT ON messages
WHEN NEW.is_encrypted = 0
 AND NEW.content GLOB '*[぀-ヿ㐀-䶿一-鿿豈-﫿က-႟฀-໿ក-៿𠀀-𪛟]*'
BEGIN
    INSERT INTO message_trigram_fts (rowid, content) VALUES (NEW.fts_rowid, NEW.content);
END;

CREATE TRIGGER message_trigram_au AFTER UPDATE OF content, is_encrypted, fts_rowid ON messages BEGIN
    DELETE FROM message_trigram_fts WHERE rowid = OLD.fts_rowid;
    INSERT INTO message_trigram_fts (rowid, content)
    SELECT NEW.fts_rowid, NEW.content
    WHERE NEW.is_encrypted = 0
      AND NEW.content GLOB '*[぀-ヿ㐀-䶿一-鿿豈-﫿က-႟฀-໿ក-៿𠀀-𪛟]*';
END;

CREATE TRIGGER message_trigram_ad AFTER DELETE ON messages BEGIN
    DELETE FROM message_trigram_fts WHERE rowid = OLD.fts_rowid;
END;

INSERT INTO message_trigram_fts (rowid, content)
SELECT fts_rowid, content FROM messages
WHERE is_encrypted = 0
  AND content GLOB '*[぀-ヿ㐀-䶿一-鿿豈-﫿က-႟฀-໿ក-៿𠀀-𪛟]*';

-- One row per piece of text: `source` names it, so each source trigger replaces only its own row.
CREATE TABLE message_extra_text (
    id         INTEGER PRIMARY KEY,
    message_id BLOB NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    source     TEXT NOT NULL,
    text       TEXT NOT NULL,
    UNIQUE (message_id, source)
) STRICT;

CREATE VIRTUAL TABLE message_extra_fts USING fts5(
    text,
    content = 'message_extra_text',
    content_rowid = 'id',
    tokenize = 'unicode61'
);

CREATE TRIGGER message_extra_text_ai AFTER INSERT ON message_extra_text BEGIN
    INSERT INTO message_extra_fts (rowid, text) VALUES (NEW.id, NEW.text);
END;

CREATE TRIGGER message_extra_text_ad AFTER DELETE ON message_extra_text BEGIN
    INSERT INTO message_extra_fts (message_extra_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
END;

INSERT INTO message_extra_text (message_id, source, text)
SELECT message_id, 'forward', origin_content FROM message_forwards WHERE origin_content <> '';

INSERT INTO message_extra_text (message_id, source, text)
SELECT message_id, 'poll', question FROM polls WHERE question <> '';

INSERT INTO message_extra_text (message_id, source, text)
SELECT message_id, 'option:' || position, label FROM poll_options WHERE label <> '';

INSERT INTO message_extra_text (message_id, source, text)
SELECT message_id, 'embed:' || position,
       trim(COALESCE(title, '') || ' ' || COALESCE(description, '') || ' '
            || COALESCE(author_name, '') || ' ' || COALESCE(footer_text, ''))
FROM message_embeds
WHERE trim(COALESCE(title, '') || COALESCE(description, '') || COALESCE(author_name, '')
           || COALESCE(footer_text, '')) <> '';

INSERT INTO message_extra_text (message_id, source, text)
SELECT message_id, 'field:' || position || ':' || field_index, name || ' ' || value
FROM message_embed_fields;

CREATE TRIGGER message_forwards_search_ai AFTER INSERT ON message_forwards
WHEN NEW.origin_content <> ''
BEGIN
    INSERT INTO message_extra_text (message_id, source, text)
    VALUES (NEW.message_id, 'forward', NEW.origin_content);
END;

CREATE TRIGGER message_forwards_search_au AFTER UPDATE OF origin_content ON message_forwards BEGIN
    DELETE FROM message_extra_text WHERE message_id = OLD.message_id AND source = 'forward';
    INSERT INTO message_extra_text (message_id, source, text)
    SELECT NEW.message_id, 'forward', NEW.origin_content WHERE NEW.origin_content <> '';
END;

CREATE TRIGGER polls_search_ai AFTER INSERT ON polls
WHEN NEW.question <> ''
BEGIN
    INSERT INTO message_extra_text (message_id, source, text)
    VALUES (NEW.message_id, 'poll', NEW.question);
END;

CREATE TRIGGER poll_options_search_ai AFTER INSERT ON poll_options
WHEN NEW.label <> ''
BEGIN
    INSERT INTO message_extra_text (message_id, source, text)
    VALUES (NEW.message_id, 'option:' || NEW.position, NEW.label);
END;

CREATE TRIGGER message_embeds_search_ai AFTER INSERT ON message_embeds
WHEN trim(COALESCE(NEW.title, '') || COALESCE(NEW.description, '')
          || COALESCE(NEW.author_name, '') || COALESCE(NEW.footer_text, '')) <> ''
BEGIN
    INSERT INTO message_extra_text (message_id, source, text)
    VALUES (NEW.message_id, 'embed:' || NEW.position,
            trim(COALESCE(NEW.title, '') || ' ' || COALESCE(NEW.description, '') || ' '
                 || COALESCE(NEW.author_name, '') || ' ' || COALESCE(NEW.footer_text, '')));
END;

CREATE TRIGGER message_embeds_search_ad AFTER DELETE ON message_embeds BEGIN
    DELETE FROM message_extra_text WHERE message_id = OLD.message_id AND source = 'embed:' || OLD.position;
END;

CREATE TRIGGER message_embed_fields_search_ai AFTER INSERT ON message_embed_fields BEGIN
    INSERT INTO message_extra_text (message_id, source, text)
    VALUES (NEW.message_id, 'field:' || NEW.position || ':' || NEW.field_index, NEW.name || ' ' || NEW.value);
END;

CREATE TRIGGER message_embed_fields_search_ad AFTER DELETE ON message_embed_fields BEGIN
    DELETE FROM message_extra_text
    WHERE message_id = OLD.message_id AND source = 'field:' || OLD.position || ':' || OLD.field_index;
END;

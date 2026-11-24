-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A deleted message keeps its row as a tombstone for op ordering and nothing
-- else: its text, earlier versions, embeds and forward snapshot go with the
-- delete, in the same statement, whichever path performed it. Blanking
-- `content` fires the full-text update trigger, which drops the search terms.
CREATE TRIGGER messages_scrub_on_delete
AFTER UPDATE OF deleted_at ON messages
WHEN NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL
BEGIN
    UPDATE messages SET content = '' WHERE id = NEW.id AND content <> '';
    DELETE FROM message_edits WHERE message_id = NEW.id;
    DELETE FROM message_embed_fields WHERE message_id = NEW.id;
    DELETE FROM message_embeds WHERE message_id = NEW.id;
    DELETE FROM message_components WHERE message_id = NEW.id;
    DELETE FROM message_annotations WHERE message_id = NEW.id;
    DELETE FROM webhook_message_usernames WHERE message_id = NEW.id;
    UPDATE message_forwards SET origin_content = ''
        WHERE message_id = NEW.id AND origin_content <> '';
END;

-- The same for everything deleted before the trigger existed.
UPDATE messages SET content = '' WHERE deleted_at IS NOT NULL AND content <> '';
DELETE FROM message_edits
    WHERE message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);
DELETE FROM message_embed_fields
    WHERE message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);
DELETE FROM message_embeds
    WHERE message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);
DELETE FROM message_components
    WHERE message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);
DELETE FROM message_annotations
    WHERE message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);
DELETE FROM webhook_message_usernames
    WHERE message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);
UPDATE message_forwards SET origin_content = ''
    WHERE origin_content <> ''
      AND message_id IN (SELECT id FROM messages WHERE deleted_at IS NOT NULL);

-- Finding copies whose original is gone walks only the forwards still showing a snapshot.
CREATE INDEX message_forwards_live_origin ON message_forwards(origin_message_id)
    WHERE origin_removed_at IS NULL;

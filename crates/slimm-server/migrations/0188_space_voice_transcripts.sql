-- Whether the server turns voice messages into text. Off by default; the
-- server needs the speech listener configured before it can be turned on.
ALTER TABLE space_settings ADD COLUMN transcribe_voice_messages INTEGER NOT NULL DEFAULT 0
    CHECK (transcribe_voice_messages IN (0, 1));

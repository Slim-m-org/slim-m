-- A reply's ping is a mention the text does not carry, so an edit re-resolving
-- the text needs to know which stored mention came from the reply rather than
-- guessing from "the parent's author is mentioned" (a text @mention of them
-- would otherwise survive an edit that removed it).
ALTER TABLE message_mentions
    ADD COLUMN via_reply INTEGER NOT NULL DEFAULT 0 CHECK (via_reply IN (0, 1));

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Whether a mention row is a direct @username outside code, not an @everyone,
-- @here, role or reply ping that reached the same person; search's mentions:
-- filter reads it. NULL until decided: rows written before this migration are
-- decided once by a startup sweep that runs the mention grammar over the text,
-- which SQL cannot do, and the partial index lets that sweep find them cheaply.
ALTER TABLE message_mentions ADD COLUMN direct INTEGER CHECK (direct IN (0, 1));

CREATE INDEX message_mentions_undecided ON message_mentions(message_id)
    WHERE direct IS NULL;

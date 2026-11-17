-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Nested categories (decision 0120): a category may sit under one top-level
-- category, two levels at most. A null parent_id is a top-level category, so
-- every existing row stays where it is.
ALTER TABLE channel_categories
    ADD COLUMN parent_id BLOB REFERENCES channel_categories(id);

-- Decision 0064's channel flag one level up: whether a sub-category's
-- overwrites are a copy of its parent's. Every existing category is top-level,
-- and a top-level category is never synced.
ALTER TABLE channel_categories
    ADD COLUMN permissions_synced INTEGER NOT NULL DEFAULT 0
    CHECK (permissions_synced IN (0, 1));

CREATE INDEX channel_categories_parent ON channel_categories(parent_id)
    WHERE parent_id IS NOT NULL;

-- The store refuses a third level with a readable error first; these refuse
-- it for any writer that forgets to ask.
CREATE TRIGGER channel_categories_two_levels_on_insert
BEFORE INSERT ON channel_categories
WHEN NEW.parent_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a category nests two levels at most')
    WHERE NEW.parent_id = NEW.id
       OR NOT EXISTS (
           SELECT 1 FROM channel_categories p
           WHERE p.id = NEW.parent_id
             AND p.parent_id IS NULL
             AND p.deleted_at IS NULL
       );
END;

CREATE TRIGGER channel_categories_two_levels_on_update
BEFORE UPDATE OF parent_id ON channel_categories
WHEN NEW.parent_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'a category nests two levels at most')
    WHERE NEW.parent_id = NEW.id
       OR NOT EXISTS (
           SELECT 1 FROM channel_categories p
           WHERE p.id = NEW.parent_id
             AND p.parent_id IS NULL
             AND p.deleted_at IS NULL
       )
       OR EXISTS (
           SELECT 1 FROM channel_categories c
           WHERE c.parent_id = NEW.id
             AND c.deleted_at IS NULL
       );
END;

-- A delete moves its sub-categories to the top level before the row goes.
CREATE TRIGGER channel_categories_delete_moves_children_out
BEFORE UPDATE OF deleted_at ON channel_categories
WHEN NEW.deleted_at IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'move its sub-categories out before deleting a category')
    WHERE EXISTS (
        SELECT 1 FROM channel_categories c
        WHERE c.parent_id = NEW.id
          AND c.deleted_at IS NULL
    );
END;

-- A temporary room now follows its lobby's rows on every write (decision 0065);
-- this is the same copy for the live rooms that drifted before it did.
DELETE FROM channel_overwrites
WHERE channel_id IN (
    SELECT id FROM channels
    WHERE room_lobby_id IS NOT NULL AND deleted_at IS NULL
);

INSERT INTO channel_overwrites (channel_id, target_type, target_id, allow, deny)
SELECT r.id, o.target_type, o.target_id, o.allow, o.deny
FROM channels r
JOIN channel_overwrites o ON o.channel_id = r.room_lobby_id
WHERE r.room_lobby_id IS NOT NULL AND r.deleted_at IS NULL;

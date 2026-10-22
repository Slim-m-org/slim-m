-- The host-written marker for a module post: the module's name as installed,
-- kept so it outlives an uninstall, and whether nobody invoked the run.
-- Rows from before this migration keep an empty name and read as person-run.
ALTER TABLE module_message_origins ADD COLUMN module_name TEXT NOT NULL DEFAULT '';
ALTER TABLE module_message_origins ADD COLUMN background INTEGER NOT NULL DEFAULT 0;

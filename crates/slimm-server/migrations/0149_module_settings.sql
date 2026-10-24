-- Admin-chosen values for a module's declared settings (decision 0091). Each
-- value is JSON text. The cascade wipes them on uninstall; a reinstall upserts
-- the module row in place, so they survive it.
CREATE TABLE module_settings (
    module_id  TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    key        TEXT NOT NULL,
    value      TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (module_id, key)
) STRICT;

-- Module platform phase 1 (decision 0091): what a manifest declares beyond
-- 0064-0146, recorded at install. Rows from before it read as addon_api 0 with
-- nothing declared, so an older module behaves exactly as it did.
ALTER TABLE installed_modules ADD COLUMN addon_api INTEGER NOT NULL DEFAULT 0;
ALTER TABLE installed_modules ADD COLUMN subscriptions TEXT NOT NULL DEFAULT '[]';
ALTER TABLE installed_modules ADD COLUMN data_schema TEXT NOT NULL DEFAULT 'null';
ALTER TABLE installed_modules ADD COLUMN settings_schema TEXT NOT NULL DEFAULT '[]';
ALTER TABLE installed_modules ADD COLUMN slots TEXT NOT NULL DEFAULT '[]';

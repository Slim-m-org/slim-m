-- The manifest.json an installed module was approved from, kept verbatim so an
-- install can be exported as a package file (decision 0090, section 9). Null for
-- a module installed before this column existed; reinstalling fills it.
ALTER TABLE installed_modules ADD COLUMN manifest_json TEXT;

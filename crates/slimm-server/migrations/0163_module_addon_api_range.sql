-- The newest add-on API a module declares it works with (decision 0100). NULL
-- means it names no upper bound; rows from before it read that way.
ALTER TABLE installed_modules ADD COLUMN addon_api_max INTEGER;

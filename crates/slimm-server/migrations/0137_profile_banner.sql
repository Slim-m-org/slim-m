-- A profile banner image beside the profile colour (decision 0074).
-- NULL means "no banner": the colour is drawn instead. The value is when the
-- image was last set, used only as a cache-busting version; the bytes live on
-- disk keyed by user id, like an avatar (migration 0013).
ALTER TABLE users ADD COLUMN banner_updated_at INTEGER;

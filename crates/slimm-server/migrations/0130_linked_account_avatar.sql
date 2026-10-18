-- When the server last stored a picture for this link; NULL means none, and
-- the client shows the provider mark instead. The bytes live in the avatar
-- directory, not here.
ALTER TABLE linked_accounts ADD COLUMN avatar_updated_at INTEGER;

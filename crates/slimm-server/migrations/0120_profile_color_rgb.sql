-- A custom profile colour beside the preset index (0075), which stays as the
-- nearest preset so a client that predates this still shows something close.
ALTER TABLE users
    ADD COLUMN profile_color_rgb INTEGER
    CHECK (profile_color_rgb IS NULL OR profile_color_rgb BETWEEN 0 AND 16777215);

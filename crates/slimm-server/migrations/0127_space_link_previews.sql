-- Whether this space unfurls pasted links into preview cards. Null follows
-- the operator's SLIMM_LINK_PREVIEWS, so a deployment that predates this
-- setting behaves as before until an admin chooses; 0 and 1 override it.
ALTER TABLE space_settings ADD COLUMN link_previews INTEGER CHECK (link_previews IN (0, 1));

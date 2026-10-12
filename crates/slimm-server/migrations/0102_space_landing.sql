-- SPDX-License-Identifier: AGPL-3.0-only
-- The public face of an invite link: an optional banner image and a short
-- description an admin sets, shown on the landing card before sign-in.
-- The banner bytes live in the media root; this only records when they were set.
-- The length cap is enforced in Rust so it can move without a migration.
ALTER TABLE space_settings ADD COLUMN banner_updated_at INTEGER;
ALTER TABLE space_settings ADD COLUMN description TEXT NOT NULL DEFAULT '';

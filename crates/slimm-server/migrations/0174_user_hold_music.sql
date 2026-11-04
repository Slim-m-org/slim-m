-- SPDX-License-Identifier: AGPL-3.0-only
-- Whether a member wants hold music while alone in a call, as an account
-- choice so every device of theirs agrees. NULL means never chosen: a client
-- with a local value then uploads it, so nobody loses the setting they had.
ALTER TABLE users ADD COLUMN hold_music_enabled INTEGER;

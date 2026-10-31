-- SPDX-License-Identifier: AGPL-3.0-only
-- What a watch party offers a viewer who would rather play the title
-- themselves (docs/decisions/0050): the address to reach the media server at
-- and which members hold a link to an account there, as one JSON object the
-- bot restates on every session write. NULL means direct play is not offered.
ALTER TABLE watch_sessions ADD COLUMN direct_play TEXT;

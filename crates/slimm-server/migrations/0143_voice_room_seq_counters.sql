-- SPDX-License-Identifier: AGPL-3.0-only
-- Temporary voice rooms were created without their message and canvas seq
-- counters, so every send and stroke there failed; they never held a row, so 1 is right.
INSERT OR IGNORE INTO channel_seq_counters (channel_id, stream, next_seq)
SELECT c.id, s.stream, 1
FROM channels c
CROSS JOIN (SELECT 'message' AS stream UNION ALL SELECT 'canvas') s;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Who was shown a webhook's current URL. `created_by` stays the minter for the
-- admin listing; this one moves to whoever rotates it, so removing a member
-- revokes only the URLs they actually hold. Existing rows were never rotated
-- in a way anything recorded, so they start at their minter.
ALTER TABLE webhooks ADD COLUMN token_issued_by BLOB REFERENCES users(id) ON DELETE SET NULL;
UPDATE webhooks SET token_issued_by = created_by;

-- A removal looks up the live credentials its member was shown.
CREATE INDEX webhooks_token_issued_by ON webhooks(token_issued_by)
    WHERE token_issued_by IS NOT NULL;
CREATE INDEX bot_tokens_live_created_by ON bot_tokens(created_by)
    WHERE revoked_at IS NULL AND created_by IS NOT NULL;

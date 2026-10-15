-- SPDX-License-Identifier: AGPL-3.0-only
-- An admin-set ceiling on a single attachment, below the operator's
-- SLIMM_ATTACHMENT_MAX_BYTES. 0 means no admin ceiling, so every deployment
-- keeps the operator's limit on upgrade. Rust enforces the settable range
-- (never above the operator's ceiling); the CHECK guards only the invariant.
ALTER TABLE space_settings ADD COLUMN attachment_max_bytes INTEGER NOT NULL DEFAULT 0
    CHECK (attachment_max_bytes >= 0);

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A scoped `clear` narrows the fence to some object kinds and/or one author.
-- Replaying the op log has to apply the same narrowing, so both are stored on
-- the op. NULL on both is the old whole-canvas clear. `clear_author_id` has no
-- foreign key on purpose: a SET NULL on account deletion would turn a scoped
-- clear into a whole-canvas one on replay.
ALTER TABLE canvas_ops ADD COLUMN clear_kinds TEXT;
ALTER TABLE canvas_ops ADD COLUMN clear_author_id BLOB;

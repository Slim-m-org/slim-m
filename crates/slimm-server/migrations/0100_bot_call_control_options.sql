-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A call control may offer a choice (a stream's quality, say): its options are
-- a JSON array of {id, label}, NULL for a plain button. The choice a member made
-- rides on the interaction so a retried use is the same use. See 0045.
ALTER TABLE bot_ui_entries ADD COLUMN options TEXT;
ALTER TABLE interactions ADD COLUMN option_id TEXT;

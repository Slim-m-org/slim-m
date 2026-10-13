-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A role's chosen colour, as an index into the client's role palette. Null
-- keeps the colour the client derives from the role id, which is what every
-- role showed before this column.
ALTER TABLE roles ADD COLUMN color INTEGER CHECK (color IS NULL OR color >= 0);

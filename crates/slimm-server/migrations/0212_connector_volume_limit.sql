-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- The data volume ceiling a host-run connector asks for (decision 0134, amended
-- 2026-11-23): the supervisor measures the volume and stops the connector past
-- it. NULL takes the supervisor's default.
ALTER TABLE connector_host_runs ADD COLUMN volume_mib INTEGER;

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- Two connector fixes from the 2026-11-23 review of decision 0134.
--
-- `connector_host_runs.volume_mib` is the data volume ceiling a host-run
-- connector asks for: the supervisor measures the volume and stops the
-- connector past it. NULL takes the supervisor's default.
--
-- `users.connector_principal` marks a connector's principal for good, so its
-- permission ceiling fails closed (nothing) if its module row is ever gone,
-- instead of reading as an ordinary account with every bit its roles grant.
ALTER TABLE connector_host_runs ADD COLUMN volume_mib INTEGER;

ALTER TABLE users ADD COLUMN connector_principal INTEGER NOT NULL DEFAULT 0
    CHECK (connector_principal IN (0, 1));

UPDATE users SET connector_principal = 1
WHERE id IN (SELECT bot_user_id FROM installed_modules
             WHERE provider = 'connector' AND bot_user_id IS NOT NULL);

-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
-- A host-run connector (decision 0134): the host starts the connector's
-- container through the supervisor. One row per connector the manifest asked
-- to be host-run; it goes with the module row on uninstall.
--
-- `run_id` is the UUIDv7 the supervisor names the containers by, never a
-- container id. `egress` is the JSON list of {host, port} the admin approved,
-- `egress_private` the Private network approval. Limits are what the manifest
-- asked for; NULL takes the supervisor's default.
--
-- The connector's token is never stored here: it lives only in the container's
-- environment, and a container the host has to create again gets a new one.
--
-- `refused` is set when the supervisor answered `policy` or `limit`, which the
-- host does not retry until an admin enables the connector again; `last_error`
-- is the reason the admin sees. `crash_disabled_at` is when the host turned it
-- off for crashing.
CREATE TABLE connector_host_runs (
    module_id TEXT PRIMARY KEY NOT NULL
        REFERENCES installed_modules(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL UNIQUE,
    image TEXT NOT NULL,
    egress TEXT NOT NULL DEFAULT '[]',
    egress_private INTEGER NOT NULL DEFAULT 0 CHECK (egress_private IN (0, 1)),
    volume INTEGER NOT NULL DEFAULT 0 CHECK (volume IN (0, 1)),
    memory_mib INTEGER,
    cpus REAL,
    pids INTEGER,
    refused INTEGER NOT NULL DEFAULT 0 CHECK (refused IN (0, 1)),
    last_error TEXT,
    crash_disabled_at INTEGER,
    created_at INTEGER NOT NULL
);

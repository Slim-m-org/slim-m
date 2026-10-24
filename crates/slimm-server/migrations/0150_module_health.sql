-- How a module's background runs (events and schedules) have gone: the
-- consecutive failures the circuit breaker counts, why it was disabled, and
-- how many pushed events its bounded queue dropped (decision 0091). A row
-- appears on first need; the cascade clears it on uninstall.
CREATE TABLE module_health (
    module_id            TEXT PRIMARY KEY REFERENCES installed_modules(id) ON DELETE CASCADE,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    disabled_reason      TEXT,
    events_dropped       INTEGER NOT NULL DEFAULT 0
) STRICT;

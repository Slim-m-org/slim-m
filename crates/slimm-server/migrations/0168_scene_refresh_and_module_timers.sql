-- Host-driven updates for modules. A shared app scene that asks to be redrawn
-- (`refresh_ms`) gets one row here: when the next redraw is due and when the
-- chain stops without someone pressing something. A module's one-shot timer
-- (`run_after`) is one row per (module, command, key); a new request for the
-- same key replaces the old one.
CREATE TABLE scene_refreshes (
    message_id BLOB NOT NULL PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
    due_at     INTEGER NOT NULL,
    until_at   INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX scene_refreshes_due ON scene_refreshes(due_at);

CREATE TABLE module_timers (
    module_id  TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    command    TEXT NOT NULL,
    key        TEXT NOT NULL DEFAULT '',
    input      TEXT NOT NULL DEFAULT '',
    channel_id BLOB REFERENCES channels(id) ON DELETE SET NULL,
    run_at     INTEGER NOT NULL,
    PRIMARY KEY (module_id, command, key)
) STRICT, WITHOUT ROWID;

CREATE INDEX module_timers_due ON module_timers(run_at);

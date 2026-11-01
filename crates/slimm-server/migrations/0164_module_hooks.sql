-- What an installed module hooks into (decision 0100): its interceptors on a
-- message before it is stored and its deny-only permission checks. The manifest
-- declares each; the admin sets the order and whether a failure refuses the
-- action. Rows are rewritten on install and cleared with the module.
CREATE TABLE module_hooks (
    module_id   TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL CHECK (kind IN ('interceptor', 'permission')),
    hook        TEXT NOT NULL,
    phase       TEXT NOT NULL DEFAULT '',
    reads       TEXT NOT NULL DEFAULT '[]',
    priority    INTEGER NOT NULL DEFAULT 100,
    fail_closed INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (module_id, kind, hook, phase)
) STRICT;

-- What an interceptor annotated a message with, one row per module. Cleared with
-- the message or the module.
CREATE TABLE message_annotations (
    message_id BLOB NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    module_id  TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    data       TEXT NOT NULL,
    PRIMARY KEY (message_id, module_id)
) STRICT;

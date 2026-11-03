-- The voice channels an admin lets a module hear (decision 0104). A module with
-- the call.audio power hears nothing until its channel list names a call, and
-- the list starts empty. Rows go with the module and with the channel.
CREATE TABLE module_call_audio_channels (
    module_id  TEXT NOT NULL REFERENCES installed_modules(id) ON DELETE CASCADE,
    channel_id BLOB NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
    PRIMARY KEY (module_id, channel_id)
) STRICT, WITHOUT ROWID;

CREATE INDEX module_call_audio_channels_channel ON module_call_audio_channels(channel_id);

-- A bot command's arguments, with the fixed choices of each, so the composer
-- can offer a pick list instead of making the member type the value. JSON
-- text because the options are read and replaced whole with their command.
-- NULL means the command declares no options.
ALTER TABLE bot_commands ADD COLUMN options TEXT;

#ifndef RUNNER_GLOBAL_HOTKEYS_CHANNEL_H_
#define RUNNER_GLOBAL_HOTKEYS_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Serves the Dart side's `slimm/global_hotkeys` channel: `bind` installs a
// low-level keyboard hook for the given keys and reports each press and
// release back as an `event` call. The hook only observes keys, so every key
// still reaches the focused app.
void RegisterGlobalHotkeysChannel(flutter::BinaryMessenger* messenger);

// Removes the hook; safe to call when none is installed.
void UnregisterGlobalHotkeys();

#endif  // RUNNER_GLOBAL_HOTKEYS_CHANNEL_H_

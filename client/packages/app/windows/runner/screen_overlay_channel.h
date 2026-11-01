#ifndef RUNNER_SCREEN_OVERLAY_CHANNEL_H_
#define RUNNER_SCREEN_OVERLAY_CHANNEL_H_

#include <flutter/binary_messenger.h>

// Answers the Dart side's `slimm/screen_overlay` calls (`support`, `show`,
// `draw`, `hide`) for the click-through overlay in screen_overlay_win.h.
void RegisterScreenOverlayChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SCREEN_OVERLAY_CHANNEL_H_

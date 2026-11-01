// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef FLUTTER_LINUX_SCREEN_OVERLAY_CHANNEL_H_
#define FLUTTER_LINUX_SCREEN_OVERLAY_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// The runner half of ScreenOverlay (platform/screen_overlay_channel.dart): `support`, `show`, `draw` and `hide` for the click-through overlay in screen_overlay.h.
void linux_screen_overlay_channel_register(FlBinaryMessenger* messenger);

#endif  // FLUTTER_LINUX_SCREEN_OVERLAY_CHANNEL_H_

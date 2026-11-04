// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef FLUTTER_LINUX_IDLE_CHANNEL_H_
#define FLUTTER_LINUX_IDLE_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Answers `idleMs` with how long the session has been idle (0 while under the
// notification timeout), or null off Wayland or without ext-idle-notify-v1.
// The Dart side is system_idle_linux.dart in the platform package.
void linux_idle_channel_register(FlBinaryMessenger* messenger);

#endif  // FLUTTER_LINUX_IDLE_CHANNEL_H_

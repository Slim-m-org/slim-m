// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef FLUTTER_LINUX_WINDOW_SUSPENDED_CHANNEL_H_
#define FLUTTER_LINUX_WINDOW_SUSPENDED_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Tells Dart when a Wayland compositor stops painting the window; see docs/window-states.md.
void linux_window_suspended_channel_register(FlBinaryMessenger* messenger,
                                             GtkWindow* window);

#endif  // FLUTTER_LINUX_WINDOW_SUSPENDED_CHANNEL_H_

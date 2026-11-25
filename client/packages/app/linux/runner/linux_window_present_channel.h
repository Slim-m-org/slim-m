// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef FLUTTER_LINUX_WINDOW_PRESENT_CHANNEL_H_
#define FLUTTER_LINUX_WINDOW_PRESENT_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Presents the window under an xdg-activation token; the Dart side is LinuxWindowPresenter.
void linux_window_present_channel_register(FlBinaryMessenger* messenger,
                                           GtkWindow* window);

#endif  // FLUTTER_LINUX_WINDOW_PRESENT_CHANNEL_H_

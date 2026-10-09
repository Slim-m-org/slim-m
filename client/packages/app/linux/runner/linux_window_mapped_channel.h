// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef FLUTTER_LINUX_WINDOW_MAPPED_CHANNEL_H_
#define FLUTTER_LINUX_WINDOW_MAPPED_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Lets Dart ask whether the window has actually been mapped yet; the Dart
// side is DesktopWindowShell.prepareHandoff (desktop_window_shell.dart).
void linux_window_mapped_channel_register(FlBinaryMessenger* messenger,
                                          GtkWindow* window);

#endif  // FLUTTER_LINUX_WINDOW_MAPPED_CHANNEL_H_

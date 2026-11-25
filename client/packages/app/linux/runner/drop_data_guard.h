// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_DROP_DATA_GUARD_H_
#define RUNNER_DROP_DATA_GUARD_H_

#include <gtk/gtk.h>

/// Keeps a drop whose transfer failed away from the desktop_drop plugin, which
/// builds a string from the selection data without checking it for NULL.
/// Call before the plugins register, so this handler runs first.
void drop_data_guard_install(GtkWidget* view);

#endif  // RUNNER_DROP_DATA_GUARD_H_

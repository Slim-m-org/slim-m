// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "drop_data_guard.h"

namespace {

void OnDragDataReceived(GtkWidget* widget, GdkDragContext* context, gint x,
                        gint y, GtkSelectionData* data, guint info, guint time,
                        gpointer user_data) {
  if (gtk_selection_data_get_data(data) != nullptr &&
      gtk_selection_data_get_length(data) > 0) {
    return;
  }
  g_signal_stop_emission_by_name(widget, "drag-data-received");
}

}  // namespace

void drop_data_guard_install(GtkWidget* view) {
  g_signal_connect(view, "drag-data-received", G_CALLBACK(OnDragDataReceived),
                   nullptr);
}

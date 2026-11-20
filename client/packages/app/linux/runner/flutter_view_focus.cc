// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "flutter_view_focus.h"

namespace {

const char* kGestureKey = "slimm-flutter-view-focus-gesture";

void OnPressed(GtkGestureMultiPress* gesture, int n_press, double x, double y,
               gpointer user_data) {
  gtk_widget_grab_focus(GTK_WIDGET(user_data));
}

}  // namespace

void flutter_view_focus_follow_presses(GtkWidget* view) {
  gtk_widget_set_can_focus(view, TRUE);
  GtkGesture* gesture = gtk_gesture_multi_press_new(view);
  // Capture runs before FlView's own handler, which stops the press there; the gesture never claims it.
  gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture),
                                             GTK_PHASE_CAPTURE);
  gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(gesture), 0);
  g_signal_connect(gesture, "pressed", G_CALLBACK(OnPressed), view);
  g_object_set_data_full(G_OBJECT(view), kGestureKey, gesture, g_object_unref);
}

void flutter_view_focus_take_back(GtkWidget* view, GtkWidget* leaving) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(view);
  if (!GTK_IS_WINDOW(toplevel)) return;
  GtkWidget* focus = gtk_window_get_focus(GTK_WINDOW(toplevel));
  if (focus == nullptr) return;
  if (focus == leaving || gtk_widget_is_ancestor(focus, leaving)) {
    gtk_widget_grab_focus(view);
  }
}

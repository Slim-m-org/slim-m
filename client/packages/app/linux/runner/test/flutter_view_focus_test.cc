// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

/// Run by scripts/lib/test_linux_runner_focus.py under a private Xvfb.
/// The window is laid out like my_application.cc's: a stand-in for FlView (an
/// event box that takes focus and stops every press, as FlView does) inside a
/// GtkOverlay, with an entry floating over it where the YouTube webview goes.
#include <gtk/gtk.h>

#include <cstdio>

#include "../flutter_view_focus.h"

namespace {

int g_failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
      ++g_failures;                                                        \
    }                                                                      \
  } while (0)

struct Window {
  GtkWidget* window;
  GtkWidget* view;
  GtkWidget* webview;
};

gboolean StopPress(GtkWidget* widget, GdkEventButton* event, gpointer data) {
  return TRUE;
}

gboolean PlaceOverlay(GtkOverlay* overlay, GtkWidget* widget,
                      GdkRectangle* allocation, gpointer data) {
  *allocation = {300, 0, 100, 100};
  return TRUE;
}

void Settle() {
  while (gtk_events_pending()) gtk_main_iteration();
}

Window Build() {
  Window w;
  w.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(w.window), 400, 300);
  w.view = gtk_event_box_new();
  gtk_widget_set_can_focus(w.view, TRUE);
  gtk_widget_add_events(w.view, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK);
  g_signal_connect(w.view, "button-press-event", G_CALLBACK(StopPress), nullptr);
  GtkWidget* overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(overlay), w.view);
  w.webview = gtk_entry_new();
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay), w.webview);
  g_signal_connect(overlay, "get-child-position", G_CALLBACK(PlaceOverlay),
                   nullptr);
  gtk_container_add(GTK_CONTAINER(w.window), overlay);
  gtk_widget_show_all(w.window);
  Settle();
  return w;
}

GtkWidget* Focus(const Window& w) {
  return gtk_window_get_focus(GTK_WINDOW(w.window));
}

void Press(GtkWidget* widget) {
  GdkEvent* event = gdk_event_new(GDK_BUTTON_PRESS);
  event->button.window = GDK_WINDOW(g_object_ref(gtk_widget_get_window(widget)));
  event->button.button = 1;
  event->button.x = 10;
  event->button.y = 10;
  event->button.time = GDK_CURRENT_TIME;
  GdkSeat* seat = gdk_display_get_default_seat(gdk_display_get_default());
  gdk_event_set_device(event, gdk_seat_get_pointer(seat));
  gtk_main_do_event(event);
  gdk_event_free(event);
  Settle();
}

void APressInFlutterTakesTheKeyboardFromTheWebview() {
  Window w = Build();
  flutter_view_focus_follow_presses(w.view);
  gtk_widget_grab_focus(w.webview);
  CHECK(Focus(w) == w.webview);
  Press(w.view);
  CHECK(Focus(w) == w.view);
  gtk_widget_destroy(w.window);
}

void APressInTheWebviewLeavesItTheKeyboard() {
  Window w = Build();
  flutter_view_focus_follow_presses(w.view);
  gtk_widget_grab_focus(w.webview);
  Press(w.webview);
  CHECK(Focus(w) == w.webview);
  gtk_widget_destroy(w.window);
}

void HidingTheFocusedWebviewHandsTheKeyboardBack() {
  Window w = Build();
  gtk_widget_grab_focus(w.webview);
  flutter_view_focus_take_back(w.view, w.webview);
  gtk_widget_hide(w.webview);
  CHECK(Focus(w) == w.view);
  gtk_widget_destroy(w.window);
}

void HidingAnUnfocusedWebviewLeavesFocusAlone() {
  Window w = Build();
  GtkWidget* other = gtk_entry_new();
  gtk_overlay_add_overlay(GTK_OVERLAY(gtk_widget_get_parent(w.view)), other);
  gtk_widget_show(other);
  Settle();
  gtk_widget_grab_focus(other);
  flutter_view_focus_take_back(w.view, w.webview);
  CHECK(Focus(w) == other);
  gtk_widget_destroy(w.window);
}

void ARefusedWebviewCannotTakeTheKeyboard() {
  Window w = Build();
  gtk_widget_grab_focus(w.view);
  flutter_view_focus_refuse(w.view, w.webview);
  gtk_widget_grab_focus(w.webview);
  CHECK(Focus(w) == w.view);
  gtk_widget_destroy(w.window);
}

void ARefusedWebviewThatForcesFocusLosesItAtOnce() {
  Window w = Build();
  flutter_view_focus_refuse(w.view, w.webview);
  gtk_widget_set_can_focus(w.webview, TRUE);
  gtk_widget_grab_focus(w.webview);
  CHECK(Focus(w) == w.view);
  gtk_widget_destroy(w.window);
}

void RefusingTheFocusedWebviewHandsTheKeyboardBack() {
  Window w = Build();
  gtk_widget_grab_focus(w.webview);
  flutter_view_focus_refuse(w.view, w.webview);
  CHECK(Focus(w) == w.view);
  gtk_widget_destroy(w.window);
}

void ARefusedWebviewLeavesOtherWidgetsTheirFocus() {
  Window w = Build();
  GtkWidget* other = gtk_entry_new();
  gtk_overlay_add_overlay(GTK_OVERLAY(gtk_widget_get_parent(w.view)), other);
  gtk_widget_show(other);
  Settle();
  flutter_view_focus_refuse(w.view, w.webview);
  gtk_widget_grab_focus(other);
  CHECK(Focus(w) == other);
  gtk_widget_destroy(w.window);
}

}  // namespace

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  APressInFlutterTakesTheKeyboardFromTheWebview();
  APressInTheWebviewLeavesItTheKeyboard();
  HidingTheFocusedWebviewHandsTheKeyboardBack();
  HidingAnUnfocusedWebviewLeavesFocusAlone();
  ARefusedWebviewCannotTakeTheKeyboard();
  ARefusedWebviewThatForcesFocusLosesItAtOnce();
  RefusingTheFocusedWebviewHandsTheKeyboardBack();
  ARefusedWebviewLeavesOtherWidgetsTheirFocus();
  if (g_failures == 0) std::printf("flutter_view_focus_test: ok\n");
  return g_failures == 0 ? 0 : 1;
}

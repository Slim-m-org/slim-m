// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "linux_window_suspended_channel.h"

#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

namespace {

const char* kChannelName = "top.npcserver.slimm/linux_window_suspended";
// Never released: the channel and flag live as long as the one window.
FlMethodChannel* g_channel = nullptr;
gboolean g_suspended = FALSE;

// GDK turns xdg_toplevel's suspended state into this event, and into nothing else.
gboolean on_visibility(GtkWidget*, GdkEventVisibility* event, gpointer) {
  gboolean suspended = event->state == GDK_VISIBILITY_FULLY_OBSCURED;
  if (suspended == g_suspended) return FALSE;
  g_suspended = suspended;
  g_autoptr(FlValue) args = fl_value_new_bool(suspended);
  fl_method_channel_invoke_method(g_channel, "suspendedChanged", args, nullptr,
                                  nullptr, nullptr);
  return FALSE;
}

void on_method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "isSuspended") == 0) {
    g_autoptr(FlValue) reply = fl_value_new_bool(g_suspended);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(reply));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void linux_window_suspended_channel_register(FlBinaryMessenger* messenger,
                                             GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, on_method_call, nullptr,
                                            nullptr);
#ifdef GDK_WINDOWING_WAYLAND
  // X11 has its own meaning for this event and reports a minimise by itself.
  if (!GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default())) return;
  gtk_widget_add_events(GTK_WIDGET(window), GDK_VISIBILITY_NOTIFY_MASK);
  g_signal_connect(window, "visibility-notify-event",
                   G_CALLBACK(on_visibility), nullptr);
#endif
}

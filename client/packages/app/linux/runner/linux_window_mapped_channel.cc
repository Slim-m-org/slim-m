// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "linux_window_mapped_channel.h"

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

const char* kChannelName = "top.npcserver.slimm/linux_window_mapped";
// Never released: the channel and flag live as long as the one window.
FlMethodChannel* g_channel = nullptr;
// Monotonic microseconds of the first map, or -1 while unmapped.
gint64 g_mapped_at = -1;

void mark_mapped() {
  if (g_mapped_at < 0) g_mapped_at = g_get_monotonic_time();
}

gboolean on_map_event(GtkWidget*, GdkEvent*, gpointer) {
  mark_mapped();
  return FALSE;
}

void on_map(GtkWidget*, gpointer) {
  // X11 is left to map-event, which only the window manager's MapNotify raises.
#ifdef GDK_WINDOWING_X11
  if (GDK_IS_X11_DISPLAY(gdk_display_get_default())) return;
#endif
  mark_mapped();
}

void on_method_call(FlMethodChannel* channel, FlMethodCall* call, gpointer) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "isMapped") == 0) {
    gint64 on_screen_ms =
        g_mapped_at < 0 ? -1 : (g_get_monotonic_time() - g_mapped_at) / 1000;
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_int(on_screen_ms)));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void linux_window_mapped_channel_register(FlBinaryMessenger* messenger,
                                          GtkWindow* window) {
  // map-event is the window manager having shown the window; the plain map signal only says GTK asked for it.
  g_signal_connect(window, "map-event", G_CALLBACK(on_map_event), nullptr);
  g_signal_connect(window, "map", G_CALLBACK(on_map), nullptr);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, on_method_call, nullptr,
                                            nullptr);
}

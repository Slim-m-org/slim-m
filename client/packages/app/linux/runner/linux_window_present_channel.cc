// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "linux_window_present_channel.h"

namespace {

const char* kChannelName = "top.npcserver.slimm/linux_window_present";
// Never released: the channel lives as long as the one window.
FlMethodChannel* g_channel = nullptr;

void on_method_call(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;
  FlValue* args = fl_method_call_get_args(call);
  if (g_strcmp0(fl_method_call_get_name(call), "present") == 0 &&
      fl_value_get_type(args) == FL_VALUE_TYPE_STRING) {
    gtk_window_set_startup_id(window, fl_value_get_string(args));
    gtk_window_present(window);
    g_autoptr(FlValue) reply = fl_value_new_bool(TRUE);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(reply));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void linux_window_present_channel_register(FlBinaryMessenger* messenger,
                                           GtkWindow* window) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, on_method_call, window,
                                            nullptr);
}

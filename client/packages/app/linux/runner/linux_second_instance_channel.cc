// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "linux_second_instance_channel.h"

namespace {

const char* kChannelName = "top.npcserver.slimm/second_instance";
// Never released: this only ever sends, but still outlives every call.
FlMethodChannel* g_channel = nullptr;

}  // namespace

void linux_second_instance_channel_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
}

void linux_second_instance_channel_notify_focus() {
  // Defensive only: the first activation always registers this first.
  if (g_channel == nullptr) return;
  fl_method_channel_invoke_method(g_channel, "focus", nullptr, nullptr,
                                  nullptr, nullptr);
}

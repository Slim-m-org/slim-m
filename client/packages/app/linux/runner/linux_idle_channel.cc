// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "linux_idle_channel.h"

#include <gdk/gdk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#include <wayland-client.h>

#include "ext-idle-notify-v1-protocol.h"
#endif

namespace {

const char* kChannelName = "top.npcserver.slimm/linux_idle";

#ifdef GDK_WINDOWING_WAYLAND

// Idle notifications fire after this long without input; the Dart side adds the time since.
constexpr uint32_t kTimeoutMs = 60 * 1000;

struct IdleState {
  wl_display* display = nullptr;
  wl_event_queue* queue = nullptr;
  ext_idle_notifier_v1* notifier = nullptr;
  ext_idle_notification_v1* notification = nullptr;
  // Monotonic microseconds of the idled event, or -1 while the person is active.
  gint64 idled_at = -1;
  bool ready = false;
};

IdleState g_idle;

void on_idled(void*, ext_idle_notification_v1*) {
  g_idle.idled_at = g_get_monotonic_time();
  g_debug("idle: idled");
}

void on_resumed(void*, ext_idle_notification_v1*) {
  g_idle.idled_at = -1;
  g_debug("idle: resumed");
}

const ext_idle_notification_v1_listener kNotificationListener = {on_idled,
                                                                 on_resumed};

void on_global(void*, wl_registry* registry, uint32_t name,
               const char* interface, uint32_t version) {
  if (g_strcmp0(interface, ext_idle_notifier_v1_interface.name) != 0) return;
  g_idle.notifier = static_cast<ext_idle_notifier_v1*>(wl_registry_bind(
      registry, name, &ext_idle_notifier_v1_interface, 1));
}

void on_global_remove(void*, wl_registry*, uint32_t) {}

const wl_registry_listener kRegistryListener = {on_global, on_global_remove};

void setup() {
  GdkDisplay* gdk_display = gdk_display_get_default();
  if (gdk_display == nullptr || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) return;
  g_idle.display = gdk_wayland_display_get_wl_display(gdk_display);
  GdkSeat* seat = gdk_display_get_default_seat(gdk_display);
  wl_seat* wl_seat = seat == nullptr ? nullptr : gdk_wayland_seat_get_wl_seat(seat);
  if (g_idle.display == nullptr || wl_seat == nullptr) return;

  // Its own queue, so GDK's dispatching never sees our objects; GDK still reads the socket.
  g_idle.queue = wl_display_create_queue(g_idle.display);
  auto* wrapper = static_cast<wl_display*>(wl_proxy_create_wrapper(g_idle.display));
  wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(wrapper), g_idle.queue);
  wl_registry* registry = wl_display_get_registry(wrapper);
  wl_registry_add_listener(registry, &kRegistryListener, nullptr);
  wl_display_roundtrip_queue(g_idle.display, g_idle.queue);
  wl_proxy_wrapper_destroy(wrapper);
  wl_registry_destroy(registry);
  if (g_idle.notifier == nullptr) {
    g_message("idle: compositor has no ext_idle_notifier_v1");
    return;
  }
  g_idle.notification = ext_idle_notifier_v1_get_idle_notification(
      g_idle.notifier, kTimeoutMs, wl_seat);
  ext_idle_notification_v1_add_listener(g_idle.notification,
                                        &kNotificationListener, nullptr);
  wl_display_roundtrip_queue(g_idle.display, g_idle.queue);
  g_idle.ready = true;
  g_message("idle: ext_idle_notifier_v1 bound, timeout %u ms", kTimeoutMs);
}

// -1 when unsupported.
gint64 idle_ms() {
  if (!g_idle.ready) return -1;
  wl_display_dispatch_queue_pending(g_idle.display, g_idle.queue);
  if (g_idle.idled_at < 0) return 0;
  return kTimeoutMs + (g_get_monotonic_time() - g_idle.idled_at) / 1000;
}

#else
void setup() {}
gint64 idle_ms() { return -1; }
#endif

void on_method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "idleMs") == 0) {
    gint64 ms = idle_ms();
    g_autoptr(FlValue) reply = ms < 0 ? nullptr : fl_value_new_int(ms);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(reply));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

FlMethodChannel* g_channel = nullptr;

}  // namespace

void linux_idle_channel_register(FlBinaryMessenger* messenger) {
  setup();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, on_method_call, nullptr,
                                            nullptr);
}

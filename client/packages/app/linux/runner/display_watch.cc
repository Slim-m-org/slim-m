// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "display_watch.h"

namespace {

// Plugging in a monitor sends a burst of changes; the caller hears once the burst is over.
constexpr guint kSettleMs = 250;

struct Watch {
  void (*on_settled)(gpointer);
  gpointer data;
  guint timer;
};

gboolean OnSettled(gpointer user_data) {
  auto* watch = static_cast<Watch*>(user_data);
  watch->timer = 0;
  watch->on_settled(watch->data);
  return G_SOURCE_REMOVE;
}

void Schedule(gpointer user_data) {
  auto* watch = static_cast<Watch*>(user_data);
  if (watch->timer != 0) g_source_remove(watch->timer);
  watch->timer = g_timeout_add(kSettleMs, OnSettled, watch);
}

void OnMonitorNotify(GObject*, GParamSpec*, gpointer user_data) { Schedule(user_data); }

void Follow(GdkMonitor* monitor, gpointer watch) {
  g_signal_connect(monitor, "notify::geometry", G_CALLBACK(OnMonitorNotify), watch);
  g_signal_connect(monitor, "notify::scale-factor", G_CALLBACK(OnMonitorNotify), watch);
}

void OnMonitorAdded(GdkDisplay*, GdkMonitor* monitor, gpointer watch) {
  Follow(monitor, watch);
  Schedule(watch);
}

void OnMonitorRemoved(GdkDisplay*, GdkMonitor*, gpointer watch) { Schedule(watch); }

// X11 reports a new primary only here.
void OnMonitorsChanged(GdkScreen*, gpointer watch) { Schedule(watch); }

}  // namespace

void display_watch_start(GdkDisplay* display, void (*on_settled)(gpointer), gpointer data) {
  // Never freed: it lives as long as the display, which is the app's.
  auto* watch = new Watch{on_settled, data, 0};
  g_signal_connect(display, "monitor-added", G_CALLBACK(OnMonitorAdded), watch);
  g_signal_connect(display, "monitor-removed", G_CALLBACK(OnMonitorRemoved), watch);
  g_signal_connect(gdk_display_get_default_screen(display), "monitors-changed",
                   G_CALLBACK(OnMonitorsChanged), watch);
  for (int i = 0; i < gdk_display_get_n_monitors(display); i++) {
    Follow(gdk_display_get_monitor(display, i), watch);
  }
}

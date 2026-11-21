// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_input.h"

namespace slimm_youtube {
namespace {

// The buttons held down, so a drag on the seek bar reads as a drag.
guint g_buttons = 0;

guint MaskOf(guint button) {
  switch (button) {
    case 1: return GDK_BUTTON1_MASK;
    case 2: return GDK_BUTTON2_MASK;
    case 3: return GDK_BUTTON3_MASK;
    default: return 0;
  }
}

// WebKit counts double clicks by event time, so every event carries a real one.
guint32 Now() { return static_cast<guint32>(g_get_monotonic_time() / 1000); }

GdkDevice* Pointer(GtkWidget* view) {
  GdkSeat* seat = gdk_display_get_default_seat(gtk_widget_get_display(view));
  return seat == nullptr ? nullptr : gdk_seat_get_pointer(seat);
}

GdkEvent* Crossing(GdkWindow* window, GdkEventType type, double x, double y) {
  GdkEvent* event = gdk_event_new(type);
  event->crossing.window = GDK_WINDOW(g_object_ref(window));
  event->crossing.send_event = TRUE;
  event->crossing.time = Now();
  event->crossing.x = x;
  event->crossing.y = y;
  event->crossing.x_root = x;
  event->crossing.y_root = y;
  event->crossing.mode = GDK_CROSSING_NORMAL;
  event->crossing.detail = GDK_NOTIFY_NONLINEAR;
  event->crossing.state = static_cast<GdkModifierType>(g_buttons);
  return event;
}

GdkEvent* Motion(GdkWindow* window, double x, double y) {
  GdkEvent* event = gdk_event_new(GDK_MOTION_NOTIFY);
  event->motion.window = GDK_WINDOW(g_object_ref(window));
  event->motion.send_event = TRUE;
  event->motion.time = Now();
  event->motion.x = x;
  event->motion.y = y;
  event->motion.x_root = x;
  event->motion.y_root = y;
  event->motion.state = static_cast<GdkModifierType>(g_buttons);
  return event;
}

GdkEvent* Button(GdkWindow* window, GdkEventType type, double x, double y,
                 guint button) {
  GdkEvent* event = gdk_event_new(type);
  event->button.window = GDK_WINDOW(g_object_ref(window));
  event->button.send_event = TRUE;
  event->button.time = Now();
  event->button.x = x;
  event->button.y = y;
  event->button.x_root = x;
  event->button.y_root = y;
  event->button.button = button;
  event->button.state = static_cast<GdkModifierType>(g_buttons);
  return event;
}

}  // namespace

bool ParsePointerKind(const char* name, PointerKind* out) {
  if (g_strcmp0(name, "enter") == 0) {
    *out = PointerKind::kEnter;
  } else if (g_strcmp0(name, "move") == 0) {
    *out = PointerKind::kMove;
  } else if (g_strcmp0(name, "down") == 0) {
    *out = PointerKind::kDown;
  } else if (g_strcmp0(name, "up") == 0) {
    *out = PointerKind::kUp;
  } else if (g_strcmp0(name, "leave") == 0) {
    *out = PointerKind::kLeave;
  } else {
    return false;
  }
  return true;
}

void SendPointer(GtkWidget* view, PointerKind kind, double x, double y,
                 guint button) {
  GdkWindow* window = gtk_widget_get_window(view);
  if (window == nullptr || !gtk_widget_get_realized(view)) return;
  GdkEvent* event = nullptr;
  switch (kind) {
    case PointerKind::kEnter:
      event = Crossing(window, GDK_ENTER_NOTIFY, x, y);
      break;
    case PointerKind::kLeave:
      event = Crossing(window, GDK_LEAVE_NOTIFY, x, y);
      break;
    case PointerKind::kMove:
      event = Motion(window, x, y);
      break;
    case PointerKind::kDown:
      event = Button(window, GDK_BUTTON_PRESS, x, y, button);
      g_buttons |= MaskOf(button);
      break;
    case PointerKind::kUp:
      event = Button(window, GDK_BUTTON_RELEASE, x, y, button);
      g_buttons &= ~MaskOf(button);
      break;
  }
  gdk_event_set_device(event, Pointer(view));
  gtk_widget_event(view, event);
  gdk_event_free(event);
}

void ResetPointer() { g_buttons = 0; }

}  // namespace slimm_youtube

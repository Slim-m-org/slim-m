// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef FLUTTER_DISPLAY_WATCH_H_
#define FLUTTER_DISPLAY_WATCH_H_

#include <gdk/gdk.h>

// Calls [on_settled] once a burst of monitor changes on [display] is over: one plugged in or removed, moved, resized, rescaled or made primary.
void display_watch_start(GdkDisplay* display, void (*on_settled)(gpointer), gpointer data);

#endif  // FLUTTER_DISPLAY_WATCH_H_

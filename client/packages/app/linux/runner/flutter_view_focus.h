// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_FLUTTER_VIEW_FOCUS_H_
#define RUNNER_FLUTTER_VIEW_FOCUS_H_

#include <gtk/gtk.h>

/// Gives [view] the window's keyboard focus on every press inside it. FlView
/// never takes focus back from a native sibling (the YouTube panel's
/// webview), so after a click in the player every key went to the webview
/// and no Flutter text field could be typed in.
void flutter_view_focus_follow_presses(GtkWidget* view);

/// Hands the keyboard back to [view] when [leaving], about to be hidden or
/// destroyed, holds it; GTK would otherwise leave the window with no focus.
void flutter_view_focus_take_back(GtkWidget* view, GtkWidget* leaving);

#endif  // RUNNER_FLUTTER_VIEW_FOCUS_H_

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_FLUTTER_VIEW_FOCUS_H_
#define RUNNER_FLUTTER_VIEW_FOCUS_H_

#include <gtk/gtk.h>

/// Gives [view] the window's keyboard focus on every press inside it. FlView
/// never takes focus back from a native sibling, so once one held it every
/// key went there and no Flutter text field could be typed in.
void flutter_view_focus_follow_presses(GtkWidget* view);

/// Hands the keyboard back to [view] when [leaving], about to be hidden or
/// destroyed, holds it; GTK would otherwise leave the window with no focus.
void flutter_view_focus_take_back(GtkWidget* view, GtkWidget* leaving);

/// Keeps the keyboard off [widget] for good: it cannot take focus, and if it
/// ever ends up holding it anyway the keyboard goes straight back to [view].
/// Call once [widget] is in [view]'s window.
void flutter_view_focus_refuse(GtkWidget* view, GtkWidget* widget);

#endif  // RUNNER_FLUTTER_VIEW_FOCUS_H_

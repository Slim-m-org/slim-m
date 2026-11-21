// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_INPUT_H_
#define RUNNER_YOUTUBE_PLAYER_INPUT_H_

#include <gtk/gtk.h>

/// The player's view sits outside the window where no real pointer reaches
/// it, so Flutter forwards its pointer and these become GDK events on it.
namespace slimm_youtube {

enum class PointerKind { kEnter, kMove, kDown, kUp, kLeave };

/// Parses the kind Dart sends ("enter", "move", "down", "up", "leave").
bool ParsePointerKind(const char* name, PointerKind* out);

/// Delivers one pointer event at ([x], [y]) in the view's logical pixels.
/// [button] is GDK's numbering (1 primary, 2 middle, 3 secondary).
void SendPointer(GtkWidget* view, PointerKind kind, double x, double y,
                 guint button);

/// Forgets which buttons are down, for a view that was just replaced.
void ResetPointer();

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_INPUT_H_

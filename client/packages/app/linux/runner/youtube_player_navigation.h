// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_NAVIGATION_H_
#define RUNNER_YOUTUBE_PLAYER_NAVIGATION_H_

#include <gtk/gtk.h>

/// Keeps the player's top-level document on the host page, by the rules in
/// youtube_player_policy.h, and drops WebKit's context menu.
namespace slimm_youtube {

using OpenExternally = void (*)(const char* uri);

/// Connects the guards to [view], a WebKitWebView from slimm_webkit::Load().
void GuardNavigation(GtkWidget* view, OpenExternally open_externally);

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_NAVIGATION_H_

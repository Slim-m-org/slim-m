// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_NAVIGATION_H_
#define RUNNER_YOUTUBE_PLAYER_NAVIGATION_H_

#include <gtk/gtk.h>

/// Keeps the player's top-level document on the host page: a new window, a
/// clicked link off the host, and any other navigation of the top document
/// (script, redirect, form, history) go to [open_externally] instead. The
/// player's own frames load in place, and WebKit's context menu is dropped.
namespace slimm_youtube {

/// The base URI the host page loads at; see youtube_host_page.dart.
constexpr const char* kHostOrigin = "https://top.npcserver.slimm/";

using OpenExternally = void (*)(const char* uri);

/// Whether [uri] is the host page the view was created on, fragment aside.
bool IsHostPage(const char* uri);

/// Connects the guards to [view], a WebKitWebView from slimm_webkit::Load().
void GuardNavigation(GtkWidget* view, OpenExternally open_externally);

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_NAVIGATION_H_

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_SANDBOX_H_
#define RUNNER_YOUTUBE_PLAYER_SANDBOX_H_

#include <gtk/gtk.h>

#include "webkit_loader.h"

/// What the embedded player's WebKit may do: run its web process in
/// bubblewrap where that exists, save no download and grant no permission.
namespace slimm_youtube {

/// Sandboxes the default web context when `bwrap` is on PATH and cancels its
/// downloads. Call before the first view is created, since WebKit refuses to
/// change the sandbox once a web process runs; later calls do nothing.
void ConfigureContext(const slimm_webkit::Api* api);

/// Denies every permission request [view], a WebKitWebView, raises.
void DenyPermissions(GtkWidget* view);

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_SANDBOX_H_

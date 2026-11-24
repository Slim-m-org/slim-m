// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_sandbox.h"

namespace slimm_youtube {
namespace {

// Nothing the embed streams is ever saved to disk.
void OnDownloadStarted(void* context, void* download, gpointer user_data) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  if (api->download_cancel != nullptr) api->download_cancel(download);
}

// The player asks for nothing but autoplay, which is a website policy and no prompt.
gboolean OnPermissionRequest(GtkWidget* view, void* request,
                             gpointer user_data) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  if (api->permission_request_deny != nullptr) {
    api->permission_request_deny(request);
  }
  return TRUE;
}

}  // namespace

void ConfigureContext(const slimm_webkit::Api* api) {
  static bool configured = false;
  if (configured || api->web_context_get_default == nullptr) return;
  configured = true;
  void* context = api->web_context_get_default();
  if (api->web_context_set_sandbox_enabled != nullptr &&
      g_find_program_in_path("bwrap") != nullptr) {
    api->web_context_set_sandbox_enabled(context, TRUE);
  }
  g_signal_connect(context, "download-started",
                   G_CALLBACK(OnDownloadStarted), nullptr);
}

void DenyPermissions(GtkWidget* view) {
  g_signal_connect(view, "permission-request", G_CALLBACK(OnPermissionRequest),
                   nullptr);
}

}  // namespace slimm_youtube

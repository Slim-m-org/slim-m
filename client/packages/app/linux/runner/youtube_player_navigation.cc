// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_navigation.h"

#include <cstring>

#include "webkit_loader.h"

namespace slimm_youtube {
namespace {

// WebKitPolicyDecisionType and WebKitNavigationType values from the 4.1 API.
constexpr int kNavigationAction = 0;
constexpr int kNewWindowAction = 1;
constexpr int kResponse = 2;
constexpr int kLinkClicked = 0;

OpenExternally g_open = nullptr;

// Only a response knows if it is the top document's; ignoring it keeps the host page and its script alive.
gboolean OnResponse(void* decision) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  if (!api->response_policy_decision_is_main_frame_main_resource(decision)) {
    return FALSE;
  }
  const char* uri = api->uri_request_get_uri(
      api->response_policy_decision_get_request(decision));
  if (IsHostPage(uri)) return FALSE;
  g_open(uri);
  api->policy_decision_ignore(decision);
  return TRUE;
}

// A new window or a clicked link off the host page goes to the browser before it loads anything.
gboolean OnDecidePolicy(GtkWidget* view, void* decision, int type,
                        gpointer user_data) {
  if (type == kResponse) return OnResponse(decision);
  if (type != kNavigationAction && type != kNewWindowAction) return FALSE;
  const slimm_webkit::Api* api = slimm_webkit::Load();
  void* action = api->policy_decision_get_navigation_action(decision);
  const char* uri =
      api->uri_request_get_uri(api->navigation_action_get_request(action));
  bool clicked = api->navigation_action_get_navigation_type(action) == kLinkClicked;
  if (type == kNewWindowAction || (clicked && !IsHostPage(uri))) {
    g_open(uri);
    api->policy_decision_ignore(decision);
    return TRUE;
  }
  api->policy_decision_use(decision);
  return TRUE;
}

gboolean OnContextMenu(GtkWidget* view, void* menu, void* event,
                       void* hit_test, gpointer user_data) {
  return TRUE;
}

}  // namespace

bool IsHostPage(const char* uri) {
  if (uri == nullptr) return false;
  size_t length = std::strlen(kHostOrigin);
  return std::strncmp(uri, kHostOrigin, length) == 0 &&
         (uri[length] == '\0' || uri[length] == '#');
}

void GuardNavigation(GtkWidget* view, OpenExternally open_externally) {
  g_open = open_externally;
  g_signal_connect(view, "decide-policy", G_CALLBACK(OnDecidePolicy), nullptr);
  g_signal_connect(view, "context-menu", G_CALLBACK(OnContextMenu), nullptr);
}

}  // namespace slimm_youtube

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_navigation.h"

#include "webkit_loader.h"
#include "youtube_player_policy.h"

namespace slimm_youtube {
namespace {

OpenExternally g_open = nullptr;

PolicyFacts FactsOf(const slimm_webkit::Api* api, void* decision, int type) {
  PolicyFacts facts;
  facts.decision_type = type;
  if (type == kResponse) {
    facts.main_frame_main_resource =
        api->response_policy_decision_is_main_frame_main_resource(decision);
    facts.uri = api->uri_request_get_uri(
        api->response_policy_decision_get_request(decision));
  } else if (type == kNavigationAction || type == kNewWindowAction) {
    void* action = api->policy_decision_get_navigation_action(decision);
    facts.navigation_type = api->navigation_action_get_navigation_type(action);
    facts.uri =
        api->uri_request_get_uri(api->navigation_action_get_request(action));
  }
  return facts;
}

gboolean OnDecidePolicy(GtkWidget* view, void* decision, int type,
                        gpointer user_data) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  const PolicyFacts facts = FactsOf(api, decision, type);
  switch (Decide(facts)) {
    case Verdict::kWebKitDefault:
      return FALSE;
    case Verdict::kLoad:
      api->policy_decision_use(decision);
      return TRUE;
    case Verdict::kOpenExternally:
      g_open(facts.uri);
      api->policy_decision_ignore(decision);
      return TRUE;
  }
  return FALSE;
}

gboolean OnContextMenu(GtkWidget* view, void* menu, void* event,
                       void* hit_test, gpointer user_data) {
  return TRUE;
}

}  // namespace

void GuardNavigation(GtkWidget* view, OpenExternally open_externally) {
  g_open = open_externally;
  g_signal_connect(view, "decide-policy", G_CALLBACK(OnDecidePolicy), nullptr);
  g_signal_connect(view, "context-menu", G_CALLBACK(OnContextMenu), nullptr);
}

}  // namespace slimm_youtube

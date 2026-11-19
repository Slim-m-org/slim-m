// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_YOUTUBE_PLAYER_POLICY_H_
#define RUNNER_YOUTUBE_PLAYER_POLICY_H_

#include <cstring>

/// What the player's view does with one WebKit policy decision, free of GTK
/// so scripts/lib/test_linux_runner_logic.py can run it with a plain compiler.
namespace slimm_youtube {

/// The base URI the host page loads at; see youtube_host_page.dart.
constexpr char kHostOrigin[] = "https://top.npcserver.slimm/";

// WebKitPolicyDecisionType and WebKitNavigationType values from the 4.1 API.
constexpr int kNavigationAction = 0;
constexpr int kNewWindowAction = 1;
constexpr int kResponse = 2;
constexpr int kLinkClicked = 0;

/// The facts WebKit gives for one decision; a field only matters for its type.
struct PolicyFacts {
  int decision_type = kNavigationAction;
  int navigation_type = -1;
  bool main_frame_main_resource = false;
  const char* uri = nullptr;
};

enum class Verdict { kWebKitDefault, kLoad, kOpenExternally };

/// Whether [uri] is the host page the view was created on, fragment aside.
inline bool IsHostPage(const char* uri) {
  if (uri == nullptr) return false;
  constexpr size_t length = sizeof(kHostOrigin) - 1;
  return std::strncmp(uri, kHostOrigin, length) == 0 &&
         (uri[length] == '\0' || uri[length] == '#');
}

/// A new window or a clicked link off the host page opens in the browser
/// before it loads; any other top document off the host (script, redirect,
/// form, history) is caught at its response. The player's frames load.
inline Verdict Decide(const PolicyFacts& facts) {
  switch (facts.decision_type) {
    case kResponse:
      if (!facts.main_frame_main_resource || IsHostPage(facts.uri)) {
        return Verdict::kWebKitDefault;
      }
      return Verdict::kOpenExternally;
    case kNewWindowAction:
      return Verdict::kOpenExternally;
    case kNavigationAction:
      if (facts.navigation_type == kLinkClicked && !IsHostPage(facts.uri)) {
        return Verdict::kOpenExternally;
      }
      return Verdict::kLoad;
    default:
      return Verdict::kWebKitDefault;
  }
}

}  // namespace slimm_youtube

#endif  // RUNNER_YOUTUBE_PLAYER_POLICY_H_

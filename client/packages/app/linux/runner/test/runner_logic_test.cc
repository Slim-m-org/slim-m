// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

// Run by scripts/lib/test_linux_runner_logic.py; no GTK or WebKit headers needed.
#include <cstdio>

#include "../youtube_player_policy.h"

namespace {

int g_failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
      ++g_failures;                                                        \
    }                                                                      \
  } while (0)

using slimm_youtube::Decide;
using slimm_youtube::PolicyFacts;
using slimm_youtube::Verdict;

constexpr int kOtherNavigation = 5;
constexpr int kFormSubmitted = 1;

PolicyFacts Navigation(int navigation_type, const char* uri) {
  PolicyFacts facts;
  facts.decision_type = slimm_youtube::kNavigationAction;
  facts.navigation_type = navigation_type;
  facts.uri = uri;
  return facts;
}

PolicyFacts Response(bool main_frame, const char* uri) {
  PolicyFacts facts;
  facts.decision_type = slimm_youtube::kResponse;
  facts.main_frame_main_resource = main_frame;
  facts.uri = uri;
  return facts;
}

void HostPageMatchesOnlyItself() {
  CHECK(slimm_youtube::IsHostPage("https://top.npcserver.slimm/"));
  CHECK(slimm_youtube::IsHostPage("https://top.npcserver.slimm/#t"));
  CHECK(!slimm_youtube::IsHostPage("https://top.npcserver.slimm/other"));
  CHECK(!slimm_youtube::IsHostPage("https://top.npcserver.slimm.evil/"));
  CHECK(!slimm_youtube::IsHostPage(nullptr));
}

void TheTopDocumentNeverLeavesTheHostPage() {
  CHECK(Decide(Response(true, "https://www.youtube.com/watch?v=x")) ==
        Verdict::kOpenExternally);
  CHECK(Decide(Response(true, "https://example.com/")) ==
        Verdict::kOpenExternally);
  CHECK(Decide(Response(true, "https://top.npcserver.slimm/")) ==
        Verdict::kWebKitDefault);
}

void ThePlayersOwnFramesLoad() {
  CHECK(Decide(Response(false, "https://www.youtube-nocookie.com/embed/x")) ==
        Verdict::kWebKitDefault);
  CHECK(Decide(Navigation(kOtherNavigation,
                          "https://www.youtube-nocookie.com/embed/x")) ==
        Verdict::kLoad);
}

void OtherNavigationsWaitForTheirResponse() {
  CHECK(Decide(Navigation(kFormSubmitted, "https://example.com/")) ==
        Verdict::kLoad);
  CHECK(Decide(Response(true, "https://example.com/")) ==
        Verdict::kOpenExternally);
}

void LinksAndNewWindowsOpenInTheBrowser() {
  CHECK(Decide(Navigation(slimm_youtube::kLinkClicked,
                          "https://www.youtube.com/watch?v=x")) ==
        Verdict::kOpenExternally);
  CHECK(Decide(Navigation(slimm_youtube::kLinkClicked,
                          "https://top.npcserver.slimm/")) == Verdict::kLoad);
  PolicyFacts window = Navigation(kOtherNavigation, "https://youtube.com/");
  window.decision_type = slimm_youtube::kNewWindowAction;
  CHECK(Decide(window) == Verdict::kOpenExternally);
}

}  // namespace

int main() {
  HostPageMatchesOnlyItself();
  TheTopDocumentNeverLeavesTheHostPage();
  ThePlayersOwnFramesLoad();
  OtherNavigationsWaitForTheirResponse();
  LinksAndNewWindowsOpenInTheBrowser();
  if (g_failures == 0) std::puts("ok");
  return g_failures == 0 ? 0 : 1;
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0

// Run by scripts/lib/test_linux_runner_logic.py; no GTK or WebKit headers needed.
#include <cstdio>

#include "../clipboard_image_limits.h"
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

void ClipboardImageSizesAreCapped() {
  using slimm_clipboard::ImageTooLarge;
  CHECK(!ImageTooLarge(8192, 8192));
  CHECK(ImageTooLarge(8193, 10));
  CHECK(ImageTooLarge(10, 8193));
  CHECK(ImageTooLarge(0, 10));
  CHECK(ImageTooLarge(-1, 10));
}

void AWidePanoramaStillCopies() {
  using slimm_clipboard::ImageTooLarge;
  using slimm_clipboard::WriteImageTooLarge;
  CHECK(ImageTooLarge(10000, 3000));
  CHECK(!WriteImageTooLarge(10000, 3000));
  CHECK(!WriteImageTooLarge(40000000, 1));
  CHECK(WriteImageTooLarge(8001, 5000));
  CHECK(WriteImageTooLarge(0, 10));
  CHECK(WriteImageTooLarge(-1, 10));
}

void PngSizeIsReadFromTheHeaderAlone() {
  const unsigned char png[] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A,
                               0,    0,   0,   13,  'I',  'H',  'D',  'R',
                               0,    0,   0x4E, 0x20, 0,   0,   0x27, 0x10};
  int width = 0;
  int height = 0;
  CHECK(slimm_clipboard::PngDimensions(png, sizeof(png), &width, &height));
  CHECK(width == 20000 && height == 10000);
  CHECK(slimm_clipboard::ImageTooLarge(width, height));
  CHECK(!slimm_clipboard::PngDimensions(png, 23, &width, &height));
  unsigned char bad[sizeof(png)];
  for (unsigned i = 0; i < sizeof(png); ++i) bad[i] = png[i];
  bad[1] = 'X';
  CHECK(!slimm_clipboard::PngDimensions(bad, sizeof(bad), &width, &height));
}

}  // namespace

int main() {
  ClipboardImageSizesAreCapped();
  AWidePanoramaStillCopies();
  PngSizeIsReadFromTheHeaderAlone();
  HostPageMatchesOnlyItself();
  TheTopDocumentNeverLeavesTheHostPage();
  ThePlayersOwnFramesLoad();
  OtherNavigationsWaitForTheirResponse();
  LinksAndNewWindowsOpenInTheBrowser();
  if (g_failures == 0) std::puts("ok");
  return g_failures == 0 ? 0 : 1;
}

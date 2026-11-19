// Run by scripts/lib/test_windows_runner_logic.py; no Windows headers needed.
#include <cstdint>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include "../bounded_retry.h"
#include "../hotkey_modifiers.h"
#include "../link_handoff.h"
#include "../youtube_player_geometry.h"

namespace {

int g_failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
      ++g_failures;                                                        \
    }                                                                      \
  } while (0)

constexpr uint32_t kM = 0x4D;
constexpr uint32_t kV = 0x56;

slimm::Modifiers Mods(bool ctrl, bool alt, bool shift, bool meta) {
  slimm::Modifiers mods;
  mods.ctrl = ctrl;
  mods.alt = alt;
  mods.shift = shift;
  mods.meta = meta;
  return mods;
}

slimm::Chord Toggle(bool ctrl, bool alt, bool shift, bool meta) {
  slimm::Chord chord;
  chord.wanted = Mods(ctrl, alt, shift, meta);
  return chord;
}

slimm::Chord HoldToTalk() {
  slimm::Chord chord;
  chord.shift_optional = true;
  return chord;
}

void ATogglesShiftIsExact() {
  const slimm::Chord mute = Toggle(true, false, false, false);
  const slimm::Chord deafen = Toggle(true, false, true, false);
  CHECK(slimm::ModifiersMatch(kM, mute, Mods(true, false, false, false)));
  CHECK(!slimm::ModifiersMatch(kM, mute, Mods(true, false, true, false)));
  CHECK(slimm::ModifiersMatch(kM, deafen, Mods(true, false, true, false)));
  CHECK(!slimm::ModifiersMatch(kM, deafen, Mods(true, false, false, false)));
}

void AToggleNeedsEveryModifierItNames() {
  const slimm::Chord chord = Toggle(true, true, false, true);
  CHECK(slimm::ModifiersMatch(kM, chord, Mods(true, true, false, true)));
  CHECK(!slimm::ModifiersMatch(kM, chord, Mods(true, true, false, false)));
  CHECK(!slimm::ModifiersMatch(kM, chord, Mods(false, true, false, true)));
  CHECK(!slimm::ModifiersMatch(kM, chord, Mods(true, false, false, true)));
}

void AnExtraCtrlAltOrMetaBlocksABareKey() {
  const slimm::Chord bare = Toggle(false, false, false, false);
  CHECK(slimm::ModifiersMatch(kV, bare, Mods(false, false, false, false)));
  CHECK(!slimm::ModifiersMatch(kV, bare, Mods(true, false, false, false)));
  CHECK(!slimm::ModifiersMatch(kV, bare, Mods(false, true, false, false)));
  CHECK(!slimm::ModifiersMatch(kV, bare, Mods(false, false, false, true)));
}

void HoldToTalkIgnoresAHeldShiftButNotOtherModifiers() {
  const slimm::Chord hold = HoldToTalk();
  CHECK(slimm::ModifiersMatch(kV, hold, Mods(false, false, false, false)));
  CHECK(slimm::ModifiersMatch(kV, hold, Mods(false, false, true, false)));
  CHECK(!slimm::ModifiersMatch(kV, hold, Mods(true, false, true, false)));
  CHECK(!slimm::ModifiersMatch(kV, hold, Mods(false, true, false, false)));
}

void AnOptionalShiftStillNeedsShiftWhenTheChordNamesIt() {
  slimm::Chord chord = HoldToTalk();
  chord.wanted.shift = true;
  CHECK(slimm::ModifiersMatch(kV, chord, Mods(false, false, true, false)));
  CHECK(!slimm::ModifiersMatch(kV, chord, Mods(false, false, false, false)));
}

void AModifierKeyBoundOnItsOwnIsNotComparedWithItself() {
  const slimm::Chord bare = Toggle(false, false, false, false);
  CHECK(slimm::ModifiersMatch(slimm::kVkLeftShift, bare,
                              Mods(false, false, true, false)));
  CHECK(slimm::ModifiersMatch(slimm::kVkRightControl, bare,
                              Mods(true, false, false, false)));
  CHECK(slimm::ModifiersMatch(slimm::kVkLeftMenu, bare,
                              Mods(false, true, false, false)));
  CHECK(slimm::ModifiersMatch(slimm::kVkRightWin, bare,
                              Mods(false, false, false, true)));
}

void AModifierKeyStillRejectsADifferentHeldModifier() {
  const slimm::Chord bare = Toggle(false, false, false, false);
  CHECK(!slimm::ModifiersMatch(slimm::kVkLeftShift, bare,
                               Mods(true, false, true, false)));
  CHECK(!slimm::ModifiersMatch(slimm::kVkRightControl, bare,
                               Mods(true, false, true, false)));
}

void AKeyEventSurvivesPacking() {
  for (uint32_t bits = 0; bits < 32; ++bits) {
    slimm::KeyEvent event;
    event.down = (bits & 1u) != 0;
    event.held = Mods((bits & 2u) != 0, (bits & 4u) != 0, (bits & 8u) != 0,
                      (bits & 16u) != 0);
    const slimm::KeyEvent back =
        slimm::UnpackKeyEvent(slimm::PackKeyEvent(event));
    CHECK(back.down == event.down);
    CHECK(back.held.ctrl == event.held.ctrl);
    CHECK(back.held.alt == event.held.alt);
    CHECK(back.held.shift == event.held.shift);
    CHECK(back.held.meta == event.held.meta);
  }
}

void ARetryStopsAtTheFirstSuccess() {
  int attempts = 0;
  int waits = 0;
  const bool ok = slimm::RetryWithWaits(
      7, [&attempts] { return ++attempts == 3; }, [&waits] { ++waits; });
  CHECK(ok);
  CHECK(attempts == 3);
  CHECK(waits == 2);
}

void ARetryThatNeverSucceedsWaitsOneLessThanItTries() {
  int attempts = 0;
  int waits = 0;
  const bool ok = slimm::RetryWithWaits(
      7, [&attempts] { ++attempts; return false; }, [&waits] { ++waits; });
  CHECK(!ok);
  CHECK(attempts == 7);
  CHECK(waits == 6);
}

void AFirstTrySuccessNeverWaits() {
  int waits = 0;
  CHECK(slimm::RetryWithWaits(7, [] { return true; }, [&waits] { ++waits; }));
  CHECK(waits == 0);
}

void ASingleAttemptNeverWaits() {
  int waits = 0;
  CHECK(!slimm::RetryWithWaits(1, [] { return false; }, [&waits] { ++waits; }));
  CHECK(waits == 0);
}

const std::wstring kRoot = L"C:\\Users\\Ann\\AppData\\Local\\slim-m";

bool InLayout(const std::wstring& path) {
  static const std::set<std::wstring> files = {kRoot + L"\\slim-m.exe",
                                               kRoot + L"\\current"};
  return files.count(path) != 0;
}

bool Nothing(const std::wstring&) { return false; }

void ALinkForwardsToACopyFromAnotherVersionFolder() {
  CHECK(slimm::IsSameApp(kRoot + L"\\app-0.130.95\\slimm_app.exe",
                         kRoot + L"\\APP-0.131.0\\SLIMM_APP.EXE"));
  CHECK(slimm::IsSameApp(L"D:/zip/slimm_app.exe", kRoot + L"\\slimm_app.exe"));
  CHECK(!slimm::IsSameApp(L"C:\\other\\flutter_app.exe",
                          kRoot + L"\\app-1\\slimm_app.exe"));
  CHECK(!slimm::IsSameApp(L"", kRoot + L"\\app-1\\slimm_app.exe"));
}

void OnlyASlimmArgumentIsALink() {
  CHECK(slimm::FindLinkArgument({L"--relaunch", L"SLIMM://spotify-callback?code=c"}) ==
        L"SLIMM://spotify-callback?code=c");
  CHECK(slimm::FindLinkArgument({L"--relaunch"}).empty());
  CHECK(slimm::FindLinkArgument({L"https://example.com", L"slim"}).empty());
}

void AnInstalledCopyRegistersItsLauncher() {
  CHECK(slimm::LinkHandlerFor(kRoot + L"\\app-0.131.0\\slimm_app.exe",
                              InLayout) == kRoot + L"\\slim-m.exe");
}

void ACopyOutsideTheLayoutRegistersItself() {
  const std::wstring unzipped = L"C:\\Users\\Ann\\Downloads\\slim-m\\slimm_app.exe";
  CHECK(slimm::LinkHandlerFor(unzipped, InLayout) == unzipped);
  const std::wstring no_launcher = kRoot + L"\\app-0.131.0\\slimm_app.exe";
  CHECK(slimm::LinkHandlerFor(no_launcher, Nothing) == no_launcher);
  CHECK(slimm::LinkHandlerFor(L"slimm_app.exe", InLayout) == L"slimm_app.exe");
}

void TheOpenCommandMatchesTheSetup() {
  CHECK(slimm::OpenCommandFor(kRoot + L"\\slim-m.exe") ==
        L"\"" + kRoot + L"\\slim-m.exe\" \"%1\"");
}

void ALogicalRectScalesToPhysicalPixels() {
  slimm::PixelRect rect = slimm::ToPhysical(10, 20, 360, 202.5, 1.5);
  CHECK(rect.left == 15);
  CHECK(rect.top == 30);
  CHECK(rect.right == 555);
  CHECK(rect.bottom == 334);
}

void AnEmptyOrBadRectIsNothing() {
  slimm::PixelRect empty = slimm::ToPhysical(10, 20, 0, 100, 1);
  CHECK(empty.right == 0 && empty.bottom == 0);
  slimm::PixelRect unscaled = slimm::ToPhysical(1, 2, 3, 4, 0);
  CHECK(unscaled.left == 1 && unscaled.right == 4 && unscaled.bottom == 6);
}

void OnlyTheHostPageStaysInThePlayer() {
  CHECK(slimm::IsYoutubeHostUrl(L"https://top.npcserver.slimm/youtube_host.html"));
  CHECK(!slimm::IsYoutubeHostUrl(L"https://www.youtube.com/watch?v=x"));
  CHECK(!slimm::IsYoutubeHostUrl(L"https://top.npcserver.slimm.evil.example/"));
}

void OnlyWebLinksReachTheBrowser() {
  CHECK(slimm::IsWebUrl(L"https://www.youtube.com/watch?v=x"));
  CHECK(!slimm::IsWebUrl(L"http://example.com"));
  CHECK(!slimm::IsWebUrl(L"file:///C:/Windows/system32/calc.exe"));
  CHECK(!slimm::IsWebUrl(L"ms-settings:"));
}

}  // namespace

int main() {
  ATogglesShiftIsExact();
  AToggleNeedsEveryModifierItNames();
  AnExtraCtrlAltOrMetaBlocksABareKey();
  HoldToTalkIgnoresAHeldShiftButNotOtherModifiers();
  AnOptionalShiftStillNeedsShiftWhenTheChordNamesIt();
  AModifierKeyBoundOnItsOwnIsNotComparedWithItself();
  AModifierKeyStillRejectsADifferentHeldModifier();
  AKeyEventSurvivesPacking();
  ARetryStopsAtTheFirstSuccess();
  ARetryThatNeverSucceedsWaitsOneLessThanItTries();
  AFirstTrySuccessNeverWaits();
  ASingleAttemptNeverWaits();
  ALinkForwardsToACopyFromAnotherVersionFolder();
  OnlyASlimmArgumentIsALink();
  AnInstalledCopyRegistersItsLauncher();
  ACopyOutsideTheLayoutRegistersItself();
  TheOpenCommandMatchesTheSetup();
  ALogicalRectScalesToPhysicalPixels();
  AnEmptyOrBadRectIsNothing();
  OnlyTheHostPageStaysInThePlayer();
  OnlyWebLinksReachTheBrowser();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::puts("runner logic ok");
  return 0;
}

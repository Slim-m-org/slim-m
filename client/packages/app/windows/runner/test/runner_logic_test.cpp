// Run by scripts/lib/test_windows_runner_logic.py; no Windows headers needed.
#include <cstdint>
#include <cstdio>

#include "../bounded_retry.h"
#include "../hotkey_modifiers.h"

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
  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::puts("runner logic ok");
  return 0;
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include <cstdio>
#include <string>

#include "../shortcut_identity.h"

namespace {

int g_failures = 0;

#define CHECK(condition)                                                   \
  do {                                                                     \
    if (!(condition)) {                                                    \
      std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
      ++g_failures;                                                        \
    }                                                                      \
  } while (0)

const std::wstring kRoot = L"C:\\Users\\Ann\\AppData\\Local\\slim-m";
const std::wstring kLauncher = kRoot + L"\\slim-m.exe";
const std::wstring kId = slimm::kAppUserModelId;

bool InLayout(const std::wstring&) { return true; }
bool Nothing(const std::wstring&) { return false; }

void APinOfAnOldVersionFolderMovesToTheLauncher() {
  CHECK(slimm::ShortcutTargetFor(kRoot, kRoot + L"\\app-0.131.0\\slimm_app.exe", L"") ==
        kLauncher);
  CHECK(slimm::ShortcutTargetFor(kRoot, kRoot + L"\\APP-0.131.0\\SLIMM_APP.EXE", kId) ==
        kLauncher);
}

void APinOfTheRunFolderMovesToTheLauncher() {
  CHECK(slimm::ShortcutTargetFor(kRoot, kRoot + L"\\app\\slimm_app.exe", L"") == kLauncher);
}

void ALauncherShortcutWithoutTheIdGainsIt() {
  CHECK(slimm::ShortcutTargetFor(kRoot, kLauncher, L"") == kLauncher);
  CHECK(slimm::ShortcutTargetFor(kRoot, kLauncher, L"someone.else") == kLauncher);
}

void ARightShortcutIsLeftAlone() {
  CHECK(slimm::ShortcutTargetFor(kRoot, kLauncher, kId).empty());
  CHECK(slimm::ShortcutTargetFor(kRoot, L"c:\\users\\ann\\appdata\\local\\slim-m\\SLIM-M.EXE",
                                 kId)
            .empty());
}

void AnotherAppsShortcutIsLeftAlone() {
  CHECK(slimm::ShortcutTargetFor(kRoot, L"C:\\Program Files\\Edge\\msedge.exe", L"").empty());
  CHECK(slimm::ShortcutTargetFor(kRoot, L"C:\\zip\\app\\slimm_app.exe", L"").empty());
  CHECK(slimm::ShortcutTargetFor(kRoot, kRoot + L"\\apps\\slimm_app.exe", L"").empty());
  CHECK(slimm::ShortcutTargetFor(kRoot, kRoot + L"\\app-0.131.0\\other.exe", L"").empty());
  CHECK(slimm::ShortcutTargetFor(kRoot, kRoot + L"\\slimm_app.exe", L"").empty());
  CHECK(slimm::ShortcutTargetFor(kRoot, L"", L"").empty());
}

void NothingIsRepairedOutsideTheLayout() {
  CHECK(slimm::ShortcutTargetFor(L"", kLauncher, L"").empty());
  CHECK(slimm::LayoutRootFor(L"C:\\Downloads\\slim-m\\slimm_app.exe", InLayout).empty());
  CHECK(slimm::LayoutRootFor(kRoot + L"\\app\\slimm_app.exe", Nothing).empty());
}

void TheLayoutRootIsFoundFromEitherFolder() {
  CHECK(slimm::LayoutRootFor(kRoot + L"\\app\\slimm_app.exe", InLayout) == kRoot);
  CHECK(slimm::LayoutRootFor(kRoot + L"\\app-0.132.0\\slimm_app.exe", InLayout) == kRoot);
}

}  // namespace

int main() {
  APinOfAnOldVersionFolderMovesToTheLauncher();
  APinOfTheRunFolderMovesToTheLauncher();
  ALauncherShortcutWithoutTheIdGainsIt();
  ARightShortcutIsLeftAlone();
  AnotherAppsShortcutIsLeftAlone();
  NothingIsRepairedOutsideTheLayout();
  TheLayoutRootIsFoundFromEitherFolder();
  if (g_failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", g_failures);
    return 1;
  }
  std::puts("shortcut identity ok");
  return 0;
}

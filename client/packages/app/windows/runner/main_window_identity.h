// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_MAIN_WINDOW_IDENTITY_H_
#define RUNNER_MAIN_WINDOW_IDENTITY_H_

#include <windows.h>

#include <cwchar>

namespace slimm {

/// The class Flutter's windowing gives every window Dart creates, the main
/// window and each pop-out alike.
constexpr wchar_t kHostWindowClass[] = L"FLUTTER_HOST_WINDOW";

/// The class the runner's own window had before Dart made the windows; an
/// older copy still running through an update hand-over carries it.
constexpr wchar_t kLegacyRunnerWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Set on the main window only, so it is told apart from a pop-out, which
/// shares its class; readable from another process.
constexpr wchar_t kMainWindowProperty[] = L"top.npcserver.slimm.main_window";

inline bool HasClass(HWND window, const wchar_t* name) {
  wchar_t found[64] = {};
  ::GetClassNameW(window, found, 64);
  return std::wcscmp(found, name) == 0;
}

/// The app's main window, from this or another copy, of either generation.
inline bool IsMainAppWindow(HWND window) {
  if (HasClass(window, kLegacyRunnerWindowClass)) return true;
  return HasClass(window, kHostWindowClass) &&
         ::GetPropW(window, kMainWindowProperty) != nullptr;
}

}  // namespace slimm

#endif  // RUNNER_MAIN_WINDOW_IDENTITY_H_

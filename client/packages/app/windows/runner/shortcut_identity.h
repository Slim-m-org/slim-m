// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_SHORTCUT_IDENTITY_H_
#define RUNNER_SHORTCUT_IDENTITY_H_

#include <string>

#include "link_handoff.h"

namespace slimm {

/// The one AppUserModelID of slim-m on Windows: the process, every shortcut and
/// the toasts share it, so a taskbar pin groups with the running window whichever
/// folder the launcher started it from. local_notifications.dart and slim-m.iss
/// carry the same text.
constexpr wchar_t kAppUserModelId[] = L"top.npcserver.slimm";

/// The app's file name inside a version folder or the run folder.
constexpr wchar_t kAppExecutable[] = L"slimm_app.exe";

/// Whether `target` is the app inside one of `root`'s version or run folders,
/// which is what Windows pins when the window had no AppUserModelID.
inline bool IsAppInLayout(const std::wstring& root, const std::wstring& target) {
  const std::wstring folder = ParentOf(target);
  return EqualsIgnoringCase(FileName(target), kAppExecutable) &&
         IsLayoutFolderName(folder) && EqualsIgnoringCase(ParentOf(folder), root);
}

/// The target a shortcut into the layout at `root` should have, or empty when it
/// is not slim-m's or is already right. A shortcut to the launcher only gains the
/// shared AppUserModelID; one to the app itself, as a pin made before slim-m had
/// an identity, is pointed at the launcher too, because its version folder goes
/// at the next update.
inline std::wstring ShortcutTargetFor(const std::wstring& root,
                                      const std::wstring& target,
                                      const std::wstring& app_user_model_id) {
  if (root.empty()) return std::wstring();
  const std::wstring launcher = root + L"\\" + kLauncherName;
  const bool to_launcher = EqualsIgnoringCase(target, launcher);
  if (!to_launcher && !IsAppInLayout(root, target)) return std::wstring();
  if (to_launcher && app_user_model_id == kAppUserModelId) return std::wstring();
  return launcher;
}

}  // namespace slimm

#endif  // RUNNER_SHORTCUT_IDENTITY_H_

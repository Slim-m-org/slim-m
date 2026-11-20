#ifndef RUNNER_LINK_HANDOFF_H_
#define RUNNER_LINK_HANDOFF_H_

#include <cstddef>
#include <cwctype>
#include <string>
#include <vector>

namespace slimm {

/// How Windows passes a `slimm://` link (an invite, Spotify's redirect, the
/// Discord link's hand-back) on a command line.
constexpr wchar_t kLinkScheme[] = L"slimm:";

/// The per-user layout from decision 0041: `<root>\slim-m.exe` starts the
/// version that `<root>\current` names, from `<root>\app\`, its hard-linked
/// copy of `<root>\app-<version>\`, or from that version folder itself.
constexpr wchar_t kLauncherName[] = L"slim-m.exe";
constexpr wchar_t kVersionFolderPrefix[] = L"app-";
constexpr wchar_t kRunFolder[] = L"app";
constexpr wchar_t kCurrentPointer[] = L"current";

inline bool StartsWithIgnoringCase(const std::wstring& text,
                                   const std::wstring& prefix) {
  if (text.size() < prefix.size()) return false;
  for (std::size_t i = 0; i < prefix.size(); ++i) {
    if (std::towlower(text[i]) != std::towlower(prefix[i])) return false;
  }
  return true;
}

inline bool EqualsIgnoringCase(const std::wstring& a, const std::wstring& b) {
  return a.size() == b.size() && StartsWithIgnoringCase(a, b);
}

inline std::wstring FileName(const std::wstring& path) {
  const std::size_t cut = path.find_last_of(L"\\/");
  return cut == std::wstring::npos ? path : path.substr(cut + 1);
}

inline std::wstring ParentOf(const std::wstring& path) {
  const std::size_t cut = path.find_last_of(L"\\/");
  return cut == std::wstring::npos ? std::wstring() : path.substr(0, cut);
}

/// The first of `args` (the program itself left out) that is a slim-m link,
/// or empty when there is none.
inline std::wstring FindLinkArgument(const std::vector<std::wstring>& args) {
  for (const std::wstring& arg : args) {
    if (StartsWithIgnoringCase(arg, kLinkScheme)) return arg;
  }
  return std::wstring();
}

/// Whether the process running `image` is this app. Only the file name counts:
/// the launcher may start a newer `app-<version>` folder than the running copy
/// came from, and a link for that copy must still reach it.
inline bool IsSameApp(const std::wstring& image, const std::wstring& own) {
  return !image.empty() && EqualsIgnoringCase(FileName(image), FileName(own));
}

/// Whether `folder` is named like the run folder or a version folder.
inline bool IsLayoutFolderName(const std::wstring& folder) {
  const std::wstring name = FileName(folder);
  return EqualsIgnoringCase(name, kRunFolder) ||
         StartsWithIgnoringCase(name, kVersionFolderPrefix);
}

/// The per-user layout's root when `exe` runs from it, or empty for a copy
/// run from anywhere else, such as an unzipped folder.
template <typename Exists>
std::wstring LayoutRootFor(const std::wstring& exe, Exists exists) {
  const std::wstring folder = ParentOf(exe);
  const std::wstring root = ParentOf(folder);
  if (root.empty() || !IsLayoutFolderName(folder)) return std::wstring();
  if (!exists(root + L"\\" + kLauncherName) ||
      !exists(root + L"\\" + kCurrentPointer)) {
    return std::wstring();
  }
  return root;
}

/// What `slimm://` should open for the copy at `exe`: the per-user launcher
/// when `exe` runs from the layout, so the registration survives updates, and
/// `exe` itself for a copy run from an unzipped folder.
template <typename Exists>
std::wstring LinkHandlerFor(const std::wstring& exe, Exists exists) {
  const std::wstring root = LayoutRootFor(exe, exists);
  return root.empty() ? exe : root + L"\\" + kLauncherName;
}

/// Set by the launcher on the app it starts (prepare.go has the same name).
constexpr wchar_t kFromLauncherVariable[] = L"SLIMM_FROM_LAUNCHER";

/// Passed to the launcher on a hand-over, so it waits for this copy to exit
/// before it relinks the run folder (prepare.go has the same text).
constexpr wchar_t kHandoffArgument[] = L"--from-run-folder";

/// The launcher to hand this start to, or empty to carry on: a copy in the run
/// folder that the launcher did not start (a taskbar pin of its window) would
/// skip the start count, rollback and relinking that only the launcher does.
/// Beside a running copy it only needs to hand focus over, as any second start does.
template <typename Exists>
std::wstring LauncherToHandTo(const std::wstring& exe, bool from_launcher,
                              bool another_instance, Exists exists) {
  const std::wstring folder = ParentOf(exe);
  const std::wstring root = ParentOf(folder);
  if (from_launcher || another_instance || root.empty() ||
      !EqualsIgnoringCase(FileName(folder), kRunFolder)) {
    return std::wstring();
  }
  const std::wstring launcher = root + L"\\" + kLauncherName;
  if (!exists(launcher) || !exists(root + L"\\" + kCurrentPointer)) {
    return std::wstring();
  }
  return launcher;
}

/// The launcher's command line for a hand-over from process `pid`, which it
/// waits on, followed by this start's own arguments.
inline std::wstring HandoffCommandLine(const std::wstring& launcher,
                                       unsigned long pid,
                                       const std::wstring& arguments) {
  std::wstring line = L"\"" + launcher + L"\" " + kHandoffArgument + L"=" +
                      std::to_wstring(pid);
  if (!arguments.empty()) line += L" " + arguments;
  return line;
}

/// The scheme's open command, quoted as the setup writes it.
inline std::wstring OpenCommandFor(const std::wstring& handler) {
  return L"\"" + handler + L"\" \"%1\"";
}

}  // namespace slimm

#endif  // RUNNER_LINK_HANDOFF_H_

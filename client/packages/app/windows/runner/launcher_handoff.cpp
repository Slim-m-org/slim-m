#include "launcher_handoff.h"

#include <windows.h>

#include <string>

#include "link_handoff.h"
#include "utils.h"

namespace {

bool IsFile(const std::wstring& path) {
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

}  // namespace

bool HandStartToLauncher(const wchar_t* command_line) {
  const bool from_launcher =
      ::GetEnvironmentVariableW(slimm::kFromLauncherVariable, nullptr, 0) != 0;
  ::SetEnvironmentVariableW(slimm::kFromLauncherVariable, nullptr);
  const std::wstring launcher =
      slimm::LauncherToHandTo(ExecutablePath(), from_launcher, IsFile);
  if (launcher.empty()) return false;
  std::wstring line =
      L"\"" + launcher + L"\" " + slimm::kHandoffArgument;
  if (command_line != nullptr && *command_line != L'\0') {
    line += L" ";
    line += command_line;
  }
  STARTUPINFOW startup = {sizeof(startup)};
  PROCESS_INFORMATION process = {};
  if (!::CreateProcessW(launcher.c_str(), line.data(), nullptr, nullptr, FALSE,
                        0, nullptr, nullptr, &startup, &process)) {
    return false;
  }
  ::CloseHandle(process.hThread);
  ::CloseHandle(process.hProcess);
  return true;
}

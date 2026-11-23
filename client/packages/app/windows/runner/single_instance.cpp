#include "single_instance.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cwchar>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "link_handoff.h"
#include "main_window_identity.h"
#include "utils.h"

namespace {

// Local\ scopes the name to this login session, so two users never collide.
constexpr wchar_t kMutexName[] = L"Local\\top.npcserver.slimm.instance";
constexpr wchar_t kMessageName[] = L"top.npcserver.slimm.second_instance";
// Tags a forwarded link's WM_COPYDATA; app_links uses WM_USER + 2 for its own.
constexpr ULONG_PTR kForwardedLinkId = 0x534C4D4C;
constexpr DWORD kMaxLinkBytes = 16 * 1024;
// A copy that does not answer in this long is hung; the link is dropped.
constexpr DWORD kForwardTimeoutMs = 5000;
// A restart's old copy flushes and quits within this; past it, give up.
constexpr DWORD kRelaunchWaitMs = 30000;

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

std::vector<std::wstring> LaunchArguments() {
  int count = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &count);
  std::vector<std::wstring> args;
  for (int i = 1; argv != nullptr && i < count; ++i) args.emplace_back(argv[i]);
  ::LocalFree(argv);
  return args;
}

std::wstring ImagePathOf(DWORD pid) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (process == nullptr) return std::wstring();
  std::wstring path(UNICODE_STRING_MAX_CHARS, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  const BOOL read = ::QueryFullProcessImageNameW(process, 0, path.data(), &size);
  ::CloseHandle(process);
  path.resize(read ? size : 0);
  return path;
}

struct InstanceSearch {
  std::wstring own;
  HWND found = nullptr;
};

BOOL CALLBACK MatchInstanceWindow(HWND window, LPARAM lparam) {
  auto* search = reinterpret_cast<InstanceSearch*>(lparam);
  if (!slimm::IsMainAppWindow(window)) return TRUE;
  DWORD pid = 0;
  ::GetWindowThreadProcessId(window, &pid);
  if (pid == ::GetCurrentProcessId() ||
      !slimm::IsSameApp(ImagePathOf(pid), search->own)) {
    return TRUE;
  }
  search->found = window;
  return FALSE;
}

// The copy holding the single-instance mutex, from whichever version folder it runs.
HWND FindRunningInstance() {
  InstanceSearch search{ExecutablePath()};
  ::EnumWindows(MatchInstanceWindow, reinterpret_cast<LPARAM>(&search));
  return search.found;
}

}  // namespace

UINT SecondInstanceMessage() {
  static const UINT message = ::RegisterWindowMessageW(kMessageName);
  return message;
}

bool AnotherInstanceRuns() {
  HANDLE mutex = ::OpenMutexW(SYNCHRONIZE, FALSE, kMutexName);
  if (mutex == nullptr) return false;
  ::CloseHandle(mutex);
  return true;
}

bool ClaimSingleInstance(const wchar_t* command_line) {
  // Held until the process exits; the OS releases it, even on a crash.
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (mutex == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return true;
  }
  if (command_line != nullptr && std::wcsstr(command_line, kRelaunchArgument)) {
    const DWORD waited = ::WaitForSingleObject(mutex, kRelaunchWaitMs);
    return waited == WAIT_OBJECT_0 || waited == WAIT_ABANDONED;
  }
  // The running copy may take the foreground only if this launch lends it.
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::PostMessageW(HWND_BROADCAST, SecondInstanceMessage(), 0, 0);
  return false;
}

bool ForwardLinkToRunningInstance() {
  const std::wstring link = slimm::FindLinkArgument(LaunchArguments());
  if (link.empty()) return false;
  const HWND running = FindRunningInstance();
  if (running == nullptr) return false;
  const std::string utf8 = Utf8FromUtf16(link.c_str());
  if (utf8.empty() || utf8.size() > kMaxLinkBytes) return false;
  COPYDATASTRUCT data{};
  data.dwData = kForwardedLinkId;
  data.cbData = static_cast<DWORD>(utf8.size());
  data.lpData = const_cast<char*>(utf8.data());
  DWORD_PTR taken = FALSE;
  if (!::SendMessageTimeoutW(running, WM_COPYDATA, 0,
                             reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                             kForwardTimeoutMs, &taken) ||
      taken != TRUE) {
    return false;
  }
  // The link is in; the same broadcast a plain second launch sends brings Dart's own window state forward.
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::PostMessageW(HWND_BROADCAST, SecondInstanceMessage(), 0, 0);
  return true;
}

bool OnForwardedLink(LPARAM lparam) {
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (data == nullptr || data->dwData != kForwardedLinkId) return false;
  if (data->lpData == nullptr || data->cbData == 0 ||
      data->cbData > kMaxLinkBytes || !g_channel) {
    return false;
  }
  std::string link(static_cast<const char*>(data->lpData), data->cbData);
  g_channel->InvokeMethod(
      "link", std::make_unique<flutter::EncodableValue>(std::move(link)));
  return true;
}

void RegisterSecondInstanceChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "top.npcserver.slimm/second_instance",
      &flutter::StandardMethodCodec::GetInstance());
}

void OnSecondInstance(HWND window) {
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
  if (g_channel) {
    g_channel->InvokeMethod("focus", nullptr);
  }
}

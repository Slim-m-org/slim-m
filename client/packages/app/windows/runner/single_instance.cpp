#include "single_instance.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <app_links/app_links_plugin_c_api.h>

#include <cwchar>
#include <memory>

namespace {

// Local\ scopes the name to this login session, so two users never collide.
constexpr wchar_t kMutexName[] = L"Local\\top.npcserver.slimm.instance";
constexpr wchar_t kMessageName[] = L"top.npcserver.slimm.second_instance";
constexpr wchar_t kLinkScheme[] = L"slimm:";
// A restart's old copy flushes and quits within this; past it, give up.
constexpr DWORD kRelaunchWaitMs = 30000;

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

}  // namespace

UINT SecondInstanceMessage() {
  static const UINT message = ::RegisterWindowMessageW(kMessageName);
  return message;
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

bool ForwardLinkToRunningInstance(const wchar_t* command_line) {
  if (command_line == nullptr || !std::wcsstr(command_line, kLinkScheme)) {
    return false;
  }
  if (!SendAppLinkToInstance()) {
    return false;
  }
  // The link is in; the same broadcast a plain second launch sends brings Dart's own window state forward.
  ::AllowSetForegroundWindow(ASFW_ANY);
  ::PostMessageW(HWND_BROADCAST, SecondInstanceMessage(), 0, 0);
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

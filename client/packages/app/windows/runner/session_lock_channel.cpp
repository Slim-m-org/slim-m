#include "session_lock_channel.h"

#include <wtsapi32.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HWND g_window = nullptr;
bool g_registered = false;

bool LeavesSession(WPARAM reason) {
  return reason == WTS_SESSION_LOCK || reason == WTS_CONSOLE_DISCONNECT ||
         reason == WTS_REMOTE_DISCONNECT;
}

bool ReturnsToSession(WPARAM reason) {
  return reason == WTS_SESSION_UNLOCK || reason == WTS_CONSOLE_CONNECT ||
         reason == WTS_REMOTE_CONNECT;
}

void Send(const char* method) {
  if (!g_channel) return;
  g_channel->InvokeMethod(method, std::make_unique<flutter::EncodableValue>());
}

}  // namespace

void RegisterSessionLockChannel(flutter::BinaryMessenger* messenger,
                                HWND window) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "slimm/session_lock",
      &flutter::StandardMethodCodec::GetInstance());
  g_window = window;
  g_registered =
      WTSRegisterSessionNotification(window, NOTIFY_FOR_THIS_SESSION) != FALSE;
}

void OnSessionLockMessage(UINT message, WPARAM wparam) {
  if (message == WM_WTSSESSION_CHANGE) {
    if (LeavesSession(wparam)) Send("away");
    if (ReturnsToSession(wparam)) Send("back");
  } else if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) Send("away");
    if (wparam == PBT_APMRESUMEAUTOMATIC) Send("back");
  }
}

void UnregisterSessionLockChannel() {
  if (g_registered && g_window != nullptr) {
    WTSUnRegisterSessionNotification(g_window);
  }
  g_registered = false;
  g_window = nullptr;
  g_channel = nullptr;
}

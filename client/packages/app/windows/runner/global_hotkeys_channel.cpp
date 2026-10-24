#include "global_hotkeys_channel.h"

#include <windows.h>
#include <wtsapi32.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

struct Binding {
  std::string id;
  DWORD vk = 0;
  bool ctrl = false;
  bool alt = false;
  bool shift = false;
  bool meta = false;
  bool down = false;
};

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::vector<Binding> g_bindings;
HHOOK g_hook = nullptr;
HWND g_watch_window = nullptr;
bool g_session_registered = false;

constexpr UINT_PTR kHeldPollTimer = 1;
constexpr UINT kHeldPollMs = 100;
constexpr wchar_t kWatchWindowClass[] = L"SlimmGlobalHotkeyWatch";

bool KeyHeld(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

bool IsCtrlKey(DWORD vk) {
  return vk == VK_CONTROL || vk == VK_LCONTROL || vk == VK_RCONTROL;
}

bool IsAltKey(DWORD vk) {
  return vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU;
}

bool IsMetaKey(DWORD vk) { return vk == VK_LWIN || vk == VK_RWIN; }

bool ModifiersHeld(const Binding& binding) {
  if (!IsCtrlKey(binding.vk) && KeyHeld(VK_CONTROL) != binding.ctrl) {
    return false;
  }
  if (!IsAltKey(binding.vk) && KeyHeld(VK_MENU) != binding.alt) return false;
  if (binding.shift && !KeyHeld(VK_SHIFT)) return false;
  const bool meta_held = KeyHeld(VK_LWIN) || KeyHeld(VK_RWIN);
  if (!IsMetaKey(binding.vk) && meta_held != binding.meta) return false;
  return true;
}

void Notify(const std::string& id, bool pressed) {
  if (!g_channel) return;
  EncodableMap args;
  args[EncodableValue("id")] = EncodableValue(id);
  args[EncodableValue("pressed")] = EncodableValue(pressed);
  g_channel->InvokeMethod("event",
                          std::make_unique<EncodableValue>(std::move(args)));
}

// Ends every hold the Dart side still believes in, so no key stays "down".
void ReleaseHeldKeys() {
  for (Binding& binding : g_bindings) {
    if (!binding.down) continue;
    binding.down = false;
    Notify(binding.id, false);
  }
}

bool AnyKeyDown() {
  for (const Binding& binding : g_bindings) {
    if (binding.down) return true;
  }
  return false;
}

// A hook gets no key-up across a lock, a secure desktop or a dropped hook, so
// a held key is checked against the real keyboard state while it is down.
void StartHeldPoll() {
  if (g_watch_window == nullptr) return;
  SetTimer(g_watch_window, kHeldPollTimer, kHeldPollMs, nullptr);
}

void StopHeldPoll() {
  if (g_watch_window == nullptr) return;
  KillTimer(g_watch_window, kHeldPollTimer);
}

void ReleaseKeysThatAreUp() {
  for (Binding& binding : g_bindings) {
    if (!binding.down || KeyHeld(static_cast<int>(binding.vk))) continue;
    binding.down = false;
    Notify(binding.id, false);
  }
  if (!AnyKeyDown()) StopHeldPoll();
}

bool EndsInputSession(WPARAM reason) {
  return reason == WTS_SESSION_LOCK || reason == WTS_CONSOLE_DISCONNECT ||
         reason == WTS_REMOTE_DISCONNECT || reason == WTS_SESSION_LOGOFF;
}

LRESULT CALLBACK WatchProc(HWND window, UINT message, WPARAM wparam,
                           LPARAM lparam) {
  if (message == WM_TIMER && wparam == kHeldPollTimer) {
    ReleaseKeysThatAreUp();
    return 0;
  }
  if (message == WM_WTSSESSION_CHANGE && EndsInputSession(wparam)) {
    ReleaseHeldKeys();
    StopHeldPoll();
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

// Hidden and never shown: session notifications need a real window handle.
bool CreateWatchWindow() {
  if (g_watch_window != nullptr) return true;
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = WatchProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWatchWindowClass;
  if (RegisterClassW(&window_class) == 0 &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }
  g_watch_window = CreateWindowExW(0, kWatchWindowClass, L"", WS_POPUP, 0, 0,
                                   0, 0, nullptr, nullptr,
                                   GetModuleHandleW(nullptr), nullptr);
  if (g_watch_window == nullptr) return false;
  g_session_registered =
      WTSRegisterSessionNotification(g_watch_window, NOTIFY_FOR_THIS_SESSION) !=
      FALSE;
  return true;
}

void DestroyWatchWindow() {
  if (g_watch_window == nullptr) return;
  if (g_session_registered) WTSUnRegisterSessionNotification(g_watch_window);
  g_session_registered = false;
  KillTimer(g_watch_window, kHeldPollTimer);
  DestroyWindow(g_watch_window);
  g_watch_window = nullptr;
}

LRESULT CALLBACK KeyboardProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code != HC_ACTION || lparam == 0) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const bool is_down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
  const bool is_up = wparam == WM_KEYUP || wparam == WM_SYSKEYUP;
  if (is_down || is_up) {
    const auto* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
    for (Binding& binding : g_bindings) {
      if (key->vkCode != binding.vk) continue;
      if (is_down && !binding.down && ModifiersHeld(binding)) {
        binding.down = true;
        StartHeldPoll();
        Notify(binding.id, true);
      } else if (is_up && binding.down) {
        binding.down = false;
        Notify(binding.id, false);
      }
    }
  }
  // Never swallow the key: the game in front still has to receive it.
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

bool ReadBool(const EncodableMap& map, const char* name) {
  auto it = map.find(EncodableValue(name));
  if (it == map.end()) return false;
  const bool* value = std::get_if<bool>(&it->second);
  return value != nullptr && *value;
}

bool ParseBinding(const EncodableValue& value, Binding* out) {
  const auto* map = std::get_if<EncodableMap>(&value);
  if (map == nullptr) return false;
  auto id = map->find(EncodableValue("id"));
  auto vk = map->find(EncodableValue("vk"));
  if (id == map->end() || vk == map->end()) return false;
  const auto* id_text = std::get_if<std::string>(&id->second);
  const auto* vk_number = std::get_if<int32_t>(&vk->second);
  if (id_text == nullptr || vk_number == nullptr || *vk_number <= 0) {
    return false;
  }
  out->id = *id_text;
  out->vk = static_cast<DWORD>(*vk_number);
  out->ctrl = ReadBool(*map, "ctrl");
  out->alt = ReadBool(*map, "alt");
  out->shift = ReadBool(*map, "shift");
  out->meta = ReadBool(*map, "meta");
  return true;
}

void RemoveHook() {
  ReleaseHeldKeys();
  g_bindings.clear();
  if (g_hook == nullptr) return;
  UnhookWindowsHookEx(g_hook);
  g_hook = nullptr;
  DestroyWatchWindow();
}

bool Bind(const EncodableList& list) {
  std::vector<Binding> parsed;
  for (const EncodableValue& entry : list) {
    Binding binding;
    if (!ParseBinding(entry, &binding)) return false;
    parsed.push_back(binding);
  }
  if (parsed.empty()) {
    RemoveHook();
    return true;
  }
  ReleaseHeldKeys();
  g_bindings = std::move(parsed);
  if (g_hook != nullptr) return true;
  // Without the window the hook still works, only the lock and poll guards go.
  CreateWatchWindow();
  g_hook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardProc,
                             GetModuleHandleW(nullptr), 0);
  if (g_hook == nullptr) {
    g_bindings.clear();
    DestroyWatchWindow();
    return false;
  }
  return true;
}

}  // namespace

void RegisterGlobalHotkeysChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "slimm/global_hotkeys",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "bind") {
          result->NotImplemented();
          return;
        }
        const auto* list = std::get_if<EncodableList>(call.arguments());
        if (list == nullptr) {
          result->Error("bad-arguments", "bind takes a list of bindings");
          return;
        }
        result->Success(EncodableValue(Bind(*list)));
      });
}

void UnregisterGlobalHotkeys() {
  RemoveHook();
  g_channel = nullptr;
}

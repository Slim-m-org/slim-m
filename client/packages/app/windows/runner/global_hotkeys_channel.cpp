#include "global_hotkeys_channel.h"

#include <windows.h>
#include <wtsapi32.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "hotkey_modifiers.h"

namespace {

constexpr uint32_t Code(int vk) { return static_cast<uint32_t>(vk); }

static_assert(slimm::kVkShift == Code(VK_SHIFT) &&
                  slimm::kVkLeftShift == Code(VK_LSHIFT) &&
                  slimm::kVkRightShift == Code(VK_RSHIFT) &&
                  slimm::kVkControl == Code(VK_CONTROL) &&
                  slimm::kVkLeftControl == Code(VK_LCONTROL) &&
                  slimm::kVkRightControl == Code(VK_RCONTROL) &&
                  slimm::kVkMenu == Code(VK_MENU) &&
                  slimm::kVkLeftMenu == Code(VK_LMENU) &&
                  slimm::kVkRightMenu == Code(VK_RMENU) &&
                  slimm::kVkLeftWin == Code(VK_LWIN) &&
                  slimm::kVkRightWin == Code(VK_RWIN),
              "hotkey_modifiers.h must use the winuser.h key codes");

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

struct Binding {
  std::string id;
  DWORD vk = 0;
  slimm::Chord chord;
  bool down = false;
};

/// Everything here belongs to the platform thread except the two atomics, which
/// the hook thread reads.
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::vector<Binding> g_bindings;
HWND g_watch_window = nullptr;
bool g_session_registered = false;
HANDLE g_hook_thread = nullptr;
DWORD g_hook_thread_id = 0;
std::atomic<HWND> g_notify_window{nullptr};
std::atomic<bool> g_watched_keys[256];

constexpr UINT_PTR kHeldPollTimer = 1;
constexpr UINT kHeldPollMs = 100;
constexpr DWORD kHookThreadStopMs = 2000;
constexpr UINT kKeyMessage = WM_APP + 1;
constexpr wchar_t kWatchWindowClass[] = L"SlimmGlobalHotkeyWatch";

bool KeyHeld(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

slimm::Modifiers HeldModifiers() {
  slimm::Modifiers held;
  held.ctrl = KeyHeld(VK_CONTROL);
  held.alt = KeyHeld(VK_MENU);
  held.shift = KeyHeld(VK_SHIFT);
  held.meta = KeyHeld(VK_LWIN) || KeyHeld(VK_RWIN);
  return held;
}

void Notify(const std::string& id, bool pressed) {
  if (!g_channel) return;
  EncodableMap args;
  args[EncodableValue("id")] = EncodableValue(id);
  args[EncodableValue("pressed")] = EncodableValue(pressed);
  g_channel->InvokeMethod("event",
                          std::make_unique<EncodableValue>(std::move(args)));
}

void NotifyLost() {
  if (!g_channel) return;
  g_channel->InvokeMethod("lost", std::make_unique<EncodableValue>());
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

void HandleKey(DWORD vk, const slimm::KeyEvent& event) {
  for (Binding& binding : g_bindings) {
    if (vk != binding.vk) continue;
    if (event.down && !binding.down &&
        slimm::ModifiersMatch(binding.vk, binding.chord, event.held)) {
      binding.down = true;
      StartHeldPoll();
      Notify(binding.id, true);
    } else if (!event.down && binding.down) {
      binding.down = false;
      Notify(binding.id, false);
    }
  }
}

/// The hook thread passes only the keys some binding names, so every other key
/// costs it one array read.
void PublishWatchedKeys() {
  bool watched[256] = {};
  for (const Binding& binding : g_bindings) {
    if (binding.vk < 256) watched[binding.vk] = true;
  }
  for (int vk = 0; vk < 256; ++vk) g_watched_keys[vk].store(watched[vk]);
}

/// Runs on the hook thread and never blocks: Windows drops a low-level hook
/// whose callback is slow, and does not say so.
LRESULT CALLBACK KeyboardProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code != HC_ACTION || lparam == 0) {
    return CallNextHookEx(nullptr, code, wparam, lparam);
  }
  const bool is_down = wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN;
  const bool is_up = wparam == WM_KEYUP || wparam == WM_SYSKEYUP;
  const auto* key = reinterpret_cast<const KBDLLHOOKSTRUCT*>(lparam);
  const HWND target = g_notify_window.load();
  if ((is_down || is_up) && target != nullptr && key->vkCode < 256 &&
      g_watched_keys[key->vkCode].load()) {
    slimm::KeyEvent event;
    event.down = is_down;
    event.held = HeldModifiers();
    PostMessageW(target, kKeyMessage, key->vkCode,
                 static_cast<LPARAM>(slimm::PackKeyEvent(event)));
  }
  // Never swallow the key: the game in front still has to receive it.
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

struct HookStart {
  HANDLE ready = nullptr;
  bool installed = false;
};

/// Owns the hook on a thread of its own, so a stalled platform thread cannot
/// make Windows time the hook out.
DWORD WINAPI HookThreadMain(LPVOID param) {
  auto* start = static_cast<HookStart*>(param);
  MSG message = {};
  // Creates the thread's queue now, so a quit posted right after start is kept.
  PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
  SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
  HHOOK hook = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardProc,
                                 GetModuleHandleW(nullptr), 0);
  start->installed = hook != nullptr;
  SetEvent(start->ready);
  if (hook == nullptr) return 0;
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  UnhookWindowsHookEx(hook);
  return 0;
}

bool StartHookThread() {
  HookStart start;
  start.ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (start.ready == nullptr) return false;
  g_notify_window.store(g_watch_window);
  DWORD thread_id = 0;
  HANDLE thread =
      CreateThread(nullptr, 0, HookThreadMain, &start, 0, &thread_id);
  if (thread == nullptr) {
    CloseHandle(start.ready);
    return false;
  }
  WaitForSingleObject(start.ready, INFINITE);
  CloseHandle(start.ready);
  if (!start.installed) {
    CloseHandle(thread);
    return false;
  }
  g_hook_thread = thread;
  g_hook_thread_id = thread_id;
  return true;
}

void StopHookThread() {
  if (g_hook_thread == nullptr) return;
  PostThreadMessageW(g_hook_thread_id, WM_QUIT, 0, 0);
  WaitForSingleObject(g_hook_thread, kHookThreadStopMs);
  CloseHandle(g_hook_thread);
  g_hook_thread = nullptr;
  g_hook_thread_id = 0;
}

bool EndsInputSession(WPARAM reason) {
  return reason == WTS_SESSION_LOCK || reason == WTS_CONSOLE_DISCONNECT ||
         reason == WTS_REMOTE_DISCONNECT || reason == WTS_SESSION_LOGOFF;
}

bool StartsInputSession(WPARAM reason) {
  return reason == WTS_SESSION_UNLOCK || reason == WTS_CONSOLE_CONNECT ||
         reason == WTS_REMOTE_CONNECT;
}

void RemoveHook();

/// Puts the hook back after anything known to strand it; one that cannot be
/// put back ends capture and tells Dart.
void ReinstallHook() {
  if (g_bindings.empty()) return;
  ReleaseHeldKeys();
  StopHookThread();
  if (StartHookThread()) return;
  RemoveHook();
  NotifyLost();
}

LRESULT CALLBACK WatchProc(HWND window, UINT message, WPARAM wparam,
                           LPARAM lparam) {
  switch (message) {
    case kKeyMessage:
      HandleKey(static_cast<DWORD>(wparam),
                slimm::UnpackKeyEvent(static_cast<uint32_t>(lparam)));
      return 0;
    case WM_TIMER:
      if (wparam != kHeldPollTimer) break;
      ReleaseKeysThatAreUp();
      return 0;
    case WM_WTSSESSION_CHANGE:
      if (EndsInputSession(wparam)) {
        ReleaseHeldKeys();
        StopHeldPoll();
        return 0;
      }
      if (StartsInputSession(wparam)) {
        ReinstallHook();
        return 0;
      }
      break;
    case WM_POWERBROADCAST:
      if (wparam != PBT_APMRESUMEAUTOMATIC) break;
      ReinstallHook();
      return TRUE;
    default:
      break;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

/// Hidden and never shown: session and power notifications need a real window
/// handle, and it is where the hook thread's key events land.
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
  g_notify_window.store(nullptr);
  if (g_session_registered) WTSUnRegisterSessionNotification(g_watch_window);
  g_session_registered = false;
  KillTimer(g_watch_window, kHeldPollTimer);
  DestroyWindow(g_watch_window);
  g_watch_window = nullptr;
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
  out->chord.wanted.ctrl = ReadBool(*map, "ctrl");
  out->chord.wanted.alt = ReadBool(*map, "alt");
  out->chord.wanted.shift = ReadBool(*map, "shift");
  out->chord.wanted.meta = ReadBool(*map, "meta");
  out->chord.shift_optional = ReadBool(*map, "shiftOptional");
  return true;
}

void RemoveHook() {
  ReleaseHeldKeys();
  g_bindings.clear();
  PublishWatchedKeys();
  StopHookThread();
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
  PublishWatchedKeys();
  // Every bind puts the hook back, since a dropped hook looks like a live one.
  StopHookThread();
  if (!CreateWatchWindow() || !StartHookThread()) {
    RemoveHook();
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

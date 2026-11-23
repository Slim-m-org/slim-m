// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "main_window.h"

#include <dwmapi.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "clipboard_image_channel.h"
#include "global_hotkeys_channel.h"
#include "main_window_identity.h"
#include "now_playing_channel.h"
#include "popout_window_proc.h"
#include "screen_overlay_channel.h"
#include "single_instance.h"
#include "taskbar_attention_channel.h"
#include "windows_toasts_channel.h"
#include "youtube_player_channel.h"

/// Corner preference attribute and its rounded value, redefined for SDKs older
/// than 10.0.22000.0.
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

namespace {

constexpr int kCornerPreferenceRound = 2;  // DWMWCP_ROUND

// Shows the window anyway if Dart never asks, or no frame follows its ask, so it cannot stay hidden.
constexpr UINT_PTR kRevealTimer = 0x534C;
constexpr UINT kRevealDeadlineMs = 15000;
constexpr UINT kFrameDeadlineMs = 1000;

// The engine numbers views from 0, so the first window Dart creates, the main one, is the implicit view.
constexpr flutter::FlutterViewId kMainViewId = 0;

using DestroyHostWindow = void (*)(HWND);

flutter::FlutterEngine* g_engine = nullptr;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HWND g_window = nullptr;
bool g_revealed = false;
bool g_shown = false;
HBRUSH g_background = nullptr;

/// Paints what a resize exposes before Flutter draws it in the app's own
/// background, not the white Windows uses when a window has no brush.
void SetBackground(int64_t argb) {
  if (g_window == nullptr) return;
  const HBRUSH brush = ::CreateSolidBrush(
      RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF));
  ::SetClassLongPtrW(g_window, GCLP_HBRBACKGROUND,
                     reinterpret_cast<LONG_PTR>(brush));
  if (g_background != nullptr) ::DeleteObject(g_background);
  g_background = brush;
  ::InvalidateRect(g_window, nullptr, TRUE);
}

/// Shows the main window as the old runner did on its first frame: a plain
/// ShowWindow from this thread, so it is activated as a fresh launch's first
/// window is.
void ShowMainWindow() {
  if (g_shown || g_window == nullptr) return;
  g_shown = true;
  ::KillTimer(g_window, kRevealTimer);
  ::ShowWindow(g_window, SW_SHOWNORMAL);
  ::SetForegroundWindow(g_window);
}

/// Shows the window once the next frame is drawn, so what appears is a
/// painted frame at the window's current size, never an empty one.
void RequestReveal() {
  if (g_revealed) return;
  g_revealed = true;
  if (g_window == nullptr) return;
  g_engine->SetNextFrameCallback([] { ShowMainWindow(); });
  ::SetTimer(g_window, kRevealTimer, kFrameDeadlineMs, nullptr);
  const HWND content =
      ::FindWindowExW(g_window, nullptr, L"FLUTTERVIEW", nullptr);
  if (content != nullptr) {
    ::RedrawWindow(content, nullptr, nullptr, RDW_INVALIDATE);
  }
}

/// The engine shows a window on its first frame, before window_manager has
/// sized it or taken its title bar; until Dart's `reveal` the main window's
/// show is dropped, so the user first sees the finished splash.
void HoldFirstShow(LPARAM lparam) {
  auto* change = reinterpret_cast<WINDOWPOS*>(lparam);
  if ((change->flags & SWP_SHOWWINDOW) == 0) return;
  // A hidden window must not take activation either, or the launch's foreground right is spent on it.
  change->flags = (change->flags & ~static_cast<UINT>(SWP_SHOWWINDOW)) |
                  SWP_NOACTIVATE;
}

std::optional<LRESULT> HandleTopLevelMessage(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  // Until Dart reports the main window, the only window there is is that one.
  const bool is_main = g_window == nullptr || window == g_window;
  if (is_main && !g_shown && message == WM_WINDOWPOSCHANGING) {
    HoldFirstShow(lparam);
  }
  if (g_window == nullptr) return std::nullopt;
  if (!is_main) return HandlePopOutMessage(window, message, wparam, lparam);
  if (message == WM_TIMER && wparam == kRevealTimer) {
    g_revealed = true;
    ShowMainWindow();
    return 0;
  }
  if (message == WM_COPYDATA && OnForwardedLink(lparam)) return TRUE;
  if (message == SecondInstanceMessage()) {
    OnSecondInstance(window);
    return 0;
  }
  if (message == TaskbarButtonCreatedMessage()) OnTaskbarButtonCreated();
  if (message == WM_FONTCHANGE) g_engine->ReloadSystemFonts();
  return std::nullopt;
}

bool AdoptMainWindow() {
  // Plugins look the main view up from the registrar when registered, so it is first used here, once Dart has made the view.
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            g_engine->GetRegistrarForPlugin("SlimmMainWindow"));
  std::shared_ptr<flutter::FlutterView> view =
      registrar->GetViewById(kMainViewId);
  if (!view) return false;
  const HWND content = view->GetNativeWindow();
  g_window = ::GetAncestor(content, GA_ROOT);
  ::SetPropW(g_window, slimm::kMainWindowProperty, g_window);
  // So erasing the background never paints over the Flutter view.
  ::SetWindowLongPtrW(g_window, GWL_STYLE,
                      ::GetWindowLongPtrW(g_window, GWL_STYLE) | WS_CLIPCHILDREN);
  // Rounds the whole window, so the frameless splash needs no Flutter-side clip.
  ::DwmSetWindowAttribute(g_window, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &kCornerPreferenceRound,
                          sizeof(kCornerPreferenceRound));
  if (!g_revealed) {
    ::SetTimer(g_window, kRevealTimer, kRevealDeadlineMs, nullptr);
  }

  flutter::BinaryMessenger* messenger = g_engine->messenger();
  RegisterPlugins(g_engine);
  RegisterNowPlayingChannel(messenger);
  RegisterGlobalHotkeysChannel(messenger);
  RegisterSecondInstanceChannel(messenger);
  RegisterScreenOverlayChannel(messenger);
  RegisterClipboardImageChannel(messenger, g_window);
  RegisterTaskbarAttentionChannel(messenger, g_window);
  RegisterWindowsToastsChannel(messenger);
  RegisterYoutubePlayerChannel(g_engine, content);
  return true;
}

bool OnTopLevelMessage(HWND window, UINT message, WPARAM wparam,
                       LPARAM lparam, void*, LRESULT* result) {
  const std::optional<LRESULT> handled =
      HandleTopLevelMessage(window, message, wparam, lparam);
  if (!handled) return false;
  *result = *handled;
  return true;
}

void HandleCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                    result) {
  const std::string& method = call.method_name();
  if (method == "ready") {
    if (g_window == nullptr && !AdoptMainWindow()) {
      result->Error("no_main_window", "Dart has not created the main window");
      return;
    }
  } else if (method == "reveal") {
    RequestReveal();
  } else if (method == "background") {
    const auto* argb = std::get_if<int64_t>(call.arguments());
    const auto* narrow = std::get_if<int32_t>(call.arguments());
    if (argb != nullptr) {
      SetBackground(*argb);
    } else if (narrow != nullptr) {
      SetBackground(static_cast<uint32_t>(*narrow));
    }
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

BOOL CALLBACK CollectHostWindow(HWND window, LPARAM found) {
  if (slimm::HasClass(window, slimm::kHostWindowClass)) {
    reinterpret_cast<std::vector<HWND>*>(found)->push_back(window);
  }
  return TRUE;
}

}  // namespace

void ServeMainWindowReady(flutter::FlutterEngine* engine) {
  g_engine = engine;
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "top.npcserver.slimm/main_window",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleCall);
  // C API, since the wrapper would capture a main view not yet made; before Run to see the first show, before the plugins to take links and pop-out frames first.
  FlutterDesktopPluginRegistrarRegisterTopLevelWindowProcDelegate(
      engine->GetRegistrarForPlugin("SlimmMainWindow"), OnTopLevelMessage,
      nullptr);
}

void DestroyDartWindows() {
  // Off screen first, so a teardown that stalls never leaves an empty window behind.
  if (g_window != nullptr) ::ShowWindow(g_window, SW_HIDE);
  // The framework's own teardown call, which parks the view before the window goes so the raster thread never sees it freed.
  const auto destroy = reinterpret_cast<DestroyHostWindow>(::GetProcAddress(
      ::GetModuleHandleW(L"flutter_windows.dll"),
      "InternalFlutterWindows_WindowManager_OnDestroyWindow"));
  if (destroy == nullptr) return;
  std::vector<HWND> windows;
  ::EnumThreadWindows(::GetCurrentThreadId(), CollectHostWindow,
                      reinterpret_cast<LPARAM>(&windows));
  for (HWND window : windows) {
    if (window != g_window) destroy(window);
  }
  if (g_window != nullptr && ::IsWindow(g_window)) destroy(g_window);
  g_window = nullptr;
}

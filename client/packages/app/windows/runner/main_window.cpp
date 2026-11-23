// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "main_window.h"

#include <dwmapi.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
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

// The engine numbers views from 0, so the first window Dart creates, the main one, is the implicit view.
constexpr flutter::FlutterViewId kMainViewId = 0;

using DestroyHostWindow = void (*)(HWND);

flutter::FlutterEngine* g_engine = nullptr;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HWND g_window = nullptr;

std::optional<LRESULT> HandleTopLevelMessage(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  // Only the engine's windows reach a top-level delegate, so any other one is a pop-out.
  if (window != g_window) {
    return HandlePopOutMessage(window, message, wparam, lparam);
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
  // Rounds the whole window, so the frameless splash needs no Flutter-side clip.
  ::DwmSetWindowAttribute(g_window, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &kCornerPreferenceRound,
                          sizeof(kCornerPreferenceRound));
  // Before the plugins, so a forwarded link is taken before app_links sees it and a pop-out's frame before window_manager does.
  registrar->RegisterTopLevelWindowProcDelegate(HandleTopLevelMessage);

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
  g_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "ready") {
      result->NotImplemented();
      return;
    }
    if (g_window == nullptr && !AdoptMainWindow()) {
      result->Error("no_main_window", "Dart has not created the main window");
      return;
    }
    result->Success();
  });
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

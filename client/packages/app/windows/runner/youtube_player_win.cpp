// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_win.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <wrl.h>

#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

#include "youtube_player_capture.h"
#include "youtube_player_geometry.h"

namespace slimm_youtube {
namespace {

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

constexpr const wchar_t* kHostUrl =
    L"https://top.npcserver.slimm/youtube_host.html";
constexpr const wchar_t* kHostFilter = L"https://top.npcserver.slimm/*";
// The tap that asked for the video happened in Flutter, not in the page.
constexpr const wchar_t* kBrowserArguments =
    L"--autoplay-policy=no-user-gesture-required";

struct State {
  HWND parent = nullptr;
  ComPtr<IDXGIAdapter> adapter;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2CompositionController> composition;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> webview;
  std::shared_ptr<VisualCapture> capture;
  std::string html;
  MessageHandler on_message;
  std::function<void()> on_frame;
  UINT width = 0;
  UINT height = 0;
  double scale = 1;
  bool left_down = false;
  slimm::Click last_click;
  bool fullscreen = false;
  // Bumped on every Create and Destroy, so a late callback for an old view does nothing.
  int generation = 0;
};

State g;

std::wstring Wide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), size);
  return out;
}

std::string Narrow(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr,
                                 nullptr);
  std::string out(size > 0 ? size - 1 : 0, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr,
                      nullptr);
  return out;
}

// Next to the app's other per-user data, never beside the versioned exe, so an update leaves nothing behind.
std::wstring UserDataFolder() {
  PWSTR local = nullptr;
  std::wstring folder;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                     &local))) {
    folder = std::wstring(local) + L"\\slim-m\\WebView2";
  }
  CoTaskMemFree(local);
  return folder;
}

void OpenExternally(const std::wstring& url) {
  if (!slimm::IsWebUrl(url)) return;
  ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr,
                SW_SHOWNORMAL);
}

void Send(const std::string& json) {
  if (g.on_message) g.on_message(json);
}

// The page renders at Dart's size and scale into the captured visual, never onto the window.
void Apply() {
  if (!g.controller) return;
  ComPtr<ICoreWebView2Controller3> controller3;
  if (SUCCEEDED(g.controller.As(&controller3))) {
    controller3->put_RasterizationScale(g.scale);
  }
  RECT rect = {0, 0, static_cast<LONG>(g.width), static_cast<LONG>(g.height)};
  g.controller->put_Bounds(rect);
  if (g.capture) g.capture->Resize(g.width, g.height);
  g.controller->put_IsVisible(g.width > 0 && g.height > 0 ? TRUE : FALSE);
}

void ServeHostPage(ICoreWebView2WebResourceRequestedEventArgs* args) {
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(
      reinterpret_cast<const BYTE*>(g.html.data()),
      static_cast<UINT>(g.html.size())));
  ComPtr<ICoreWebView2WebResourceResponse> response;
  if (stream && SUCCEEDED(g.environment->CreateWebResourceResponse(
                    stream.Get(), 200, L"OK",
                    L"Content-Type: text/html; charset=utf-8",
                    &response))) {
    args->put_Response(response.Get());
  }
}

void Wire(ICoreWebView2* webview) {
  EventRegistrationToken token;
  webview->AddWebResourceRequestedFilter(kHostFilter,
                                         COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  webview->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) {
            ServeHostPage(args);
            return S_OK;
          })
          .Get(),
      &token);
  webview->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) {
            LPWSTR message = nullptr;
            if (SUCCEEDED(args->TryGetWebMessageAsString(&message))) {
              Send(Narrow(message));
            }
            CoTaskMemFree(message);
            return S_OK;
          })
          .Get(),
      &token);
  // The YouTube logo and "watch on YouTube" open a new window or navigate the top: both go to the browser.
  webview->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) {
            LPWSTR uri = nullptr;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri != nullptr) {
              OpenExternally(uri);
            }
            CoTaskMemFree(uri);
            args->put_Handled(TRUE);
            return S_OK;
          })
          .Get(),
      &token);
  webview->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) {
            LPWSTR uri = nullptr;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri != nullptr &&
                !slimm::IsYoutubeHostUrl(uri)) {
              OpenExternally(uri);
              args->put_Cancel(TRUE);
            }
            CoTaskMemFree(uri);
            return S_OK;
          })
          .Get(),
      &token);
  webview->add_ContainsFullScreenElementChanged(
      Callback<ICoreWebView2ContainsFullScreenElementChangedEventHandler>(
          [](ICoreWebView2* sender, IUnknown*) {
            BOOL on = FALSE;
            sender->get_ContainsFullScreenElement(&on);
            g.fullscreen = on == TRUE;
            Apply();
            Send(g.fullscreen ? "{\"event\":\"fullscreen\",\"on\":true}"
                              : "{\"event\":\"fullscreen\",\"on\":false}");
            return S_OK;
          })
          .Get(),
      &token);
  // The player needs no camera, microphone, location or the like; autoplay stays WebView2's own allow.
  webview->add_PermissionRequested(
      Callback<ICoreWebView2PermissionRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) {
            COREWEBVIEW2_PERMISSION_KIND kind =
                COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
            if (FAILED(args->get_PermissionKind(&kind)) ||
                kind != COREWEBVIEW2_PERMISSION_KIND_AUTOPLAY) {
              args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
            }
            return S_OK;
          })
          .Get(),
      &token);
  webview->add_ProcessFailed(
      Callback<ICoreWebView2ProcessFailedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*) {
            Send("{\"event\":\"error\",\"code\":-1}");
            return S_OK;
          })
          .Get(),
      &token);
}

void Configure(ICoreWebView2* webview) {
  ComPtr<ICoreWebView2Settings> settings;
  if (SUCCEEDED(webview->get_Settings(&settings))) {
    settings->put_AreDevToolsEnabled(FALSE);
    settings->put_AreDefaultContextMenusEnabled(FALSE);
    settings->put_IsStatusBarEnabled(FALSE);
    settings->put_IsZoomControlEnabled(FALSE);
  }
  // Print, find and reload belong to a browser, not a player; the keys then reach nothing.
  ComPtr<ICoreWebView2Settings3> settings3;
  if (settings && SUCCEEDED(settings.As(&settings3))) {
    settings3->put_AreBrowserAcceleratorKeysEnabled(FALSE);
  }
}

void Close(ICoreWebView2CompositionController* composition) {
  ComPtr<ICoreWebView2Controller> controller;
  if (composition != nullptr &&
      SUCCEEDED(composition->QueryInterface(IID_PPV_ARGS(&controller)))) {
    controller->Close();
  }
}

void OnController(int generation, ICoreWebView2CompositionController* composition,
                  const std::function<void(bool)>& done) {
  if (generation != g.generation || composition == nullptr) {
    Close(composition);
    done(false);
    return;
  }
  // Flutter's raster thread reads it through Latest, so it is swapped atomically.
  std::atomic_store(&g.capture,
                    VisualCapture::Create(g.adapter.Get(), g.on_frame));
  if (!g.capture ||
      FAILED(composition->put_RootVisualTarget(g.capture->RootVisual())) ||
      FAILED(composition->QueryInterface(IID_PPV_ARGS(&g.controller)))) {
    std::atomic_store(&g.capture, std::shared_ptr<VisualCapture>());
    Close(composition);
    done(false);
    return;
  }
  g.composition = composition;
  g.controller->get_CoreWebView2(&g.webview);
  ComPtr<ICoreWebView2Controller2> controller2;
  if (SUCCEEDED(g.controller.As(&controller2))) {
    COREWEBVIEW2_COLOR black = {255, 0, 0, 0};
    controller2->put_DefaultBackgroundColor(black);
  }
  // Dart says the scale with each size, since the visual never sits on a monitor.
  ComPtr<ICoreWebView2Controller3> controller3;
  if (SUCCEEDED(g.controller.As(&controller3))) {
    controller3->put_ShouldDetectMonitorScaleChanges(FALSE);
    controller3->put_BoundsMode(COREWEBVIEW2_BOUNDS_MODE_USE_RAW_PIXELS);
  }
  Configure(g.webview.Get());
  Wire(g.webview.Get());
  Apply();
  g.webview->Navigate(kHostUrl);
  done(true);
}

void CreateController(int generation, std::function<void(bool)> done) {
  auto completed = Callback<
      ICoreWebView2CreateCoreWebView2CompositionControllerCompletedHandler>(
      [generation, done](HRESULT result,
                         ICoreWebView2CompositionController* composition) {
        OnController(generation, SUCCEEDED(result) ? composition : nullptr,
                     done);
        return S_OK;
      });
  ComPtr<ICoreWebView2Environment10> environment10;
  ComPtr<ICoreWebView2ControllerOptions> options;
  if (SUCCEEDED(g.environment.As(&environment10)) &&
      SUCCEEDED(environment10->CreateCoreWebView2ControllerOptions(&options))) {
    // Nothing the player stores outlives it, in keeping with youtube-nocookie.
    options->put_IsInPrivateModeEnabled(TRUE);
    if (SUCCEEDED(environment10->CreateCoreWebView2CompositionControllerWithOptions(
            g.parent, options.Get(), completed.Get()))) {
      return;
    }
  }
  ComPtr<ICoreWebView2Environment3> environment3;
  if (FAILED(g.environment.As(&environment3)) ||
      FAILED(environment3->CreateCoreWebView2CompositionController(
          g.parent, completed.Get()))) {
    done(false);
  }
}

// WebView2 grants fullscreen only to a focused page, and a press on a hosted visual focuses nothing; the keyboard stays with Flutter.
void FocusPage() {
  if (!g.webview) return;
  g.webview->CallDevToolsProtocolMethod(
      L"Page.bringToFront", L"{}",
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [](HRESULT, LPCWSTR) { return S_OK; })
          .Get());
}

}  // namespace

bool RuntimeAvailable() {
  LPWSTR version = nullptr;
  HRESULT result = GetAvailableCoreWebView2BrowserVersionString(nullptr, &version);
  bool available = SUCCEEDED(result) && version != nullptr;
  CoTaskMemFree(version);
  return available && VisualCapture::Supported();
}

void Create(HWND parent, IDXGIAdapter* adapter, const std::string& html,
            MessageHandler on_message, std::function<void()> on_frame,
            std::function<void(bool)> done) {
  Destroy();
  g.parent = parent;
  g.adapter = adapter;
  g.html = html;
  g.on_message = std::move(on_message);
  g.on_frame = std::move(on_frame);
  int generation = g.generation;
  if (g.environment) {
    CreateController(generation, std::move(done));
    return;
  }
  auto options = Make<CoreWebView2EnvironmentOptions>();
  options->put_AdditionalBrowserArguments(kBrowserArguments);
  std::wstring folder = UserDataFolder();
  HRESULT result = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, folder.empty() ? nullptr : folder.c_str(), options.Get(),
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [generation, done](HRESULT created,
                             ICoreWebView2Environment* environment) {
            if (FAILED(created) || environment == nullptr ||
                generation != g.generation) {
              done(false);
              return S_OK;
            }
            g.environment = environment;
            CreateController(generation, done);
            return S_OK;
          })
          .Get());
  if (FAILED(result)) done(false);
}

void Resize(double width, double height, double scale) {
  g.scale = scale > 0 ? scale : 1;
  g.width = static_cast<UINT>(std::lround(std::max(width, 0.0) * g.scale));
  g.height = static_cast<UINT>(std::lround(std::max(height, 0.0) * g.scale));
  Apply();
}

void Pointer(PointerKind kind, double x, double y) {
  if (!g.composition) return;
  POINT point = {std::lround(x * g.scale), std::lround(y * g.scale)};
  COREWEBVIEW2_MOUSE_EVENT_KIND event = COREWEBVIEW2_MOUSE_EVENT_KIND_MOVE;
  switch (kind) {
    case PointerKind::kEnter:
    case PointerKind::kMove:
      break;
    case PointerKind::kLeave:
      event = COREWEBVIEW2_MOUSE_EVENT_KIND_LEAVE;
      break;
    case PointerKind::kDown: {
      // A hosted view gets no double click from Windows, so it is told one; YouTube fullscreens on it.
      slimm::Click click = {GetTickCount64(), point.x, point.y};
      bool twice = slimm::IsDoubleClick(
          g.last_click, click, GetDoubleClickTime(),
          GetSystemMetrics(SM_CXDOUBLECLK), GetSystemMetrics(SM_CYDOUBLECLK));
      g.last_click = twice ? slimm::Click{} : click;
      event = twice ? COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOUBLE_CLICK
                    : COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_DOWN;
      g.left_down = true;
      break;
    }
    case PointerKind::kUp:
      event = COREWEBVIEW2_MOUSE_EVENT_KIND_LEFT_BUTTON_UP;
      g.left_down = false;
      break;
  }
  COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS keys =
      g.left_down ? COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_LEFT_BUTTON
                  : COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS_NONE;
  // A press blurs the page, so it is focused again before the release that clicks.
  if (kind == PointerKind::kUp) FocusPage();
  g.composition->SendMouseInput(event, keys, 0, point);
}

SharedFrame Latest() {
  std::shared_ptr<VisualCapture> capture = std::atomic_load(&g.capture);
  return capture ? capture->Latest() : SharedFrame{};
}

void Run(const std::string& script) {
  if (g.webview) g.webview->ExecuteScript(Wide(script).c_str(), nullptr);
}

void Destroy() {
  g.generation++;
  g.fullscreen = false;
  g.left_down = false;
  g.webview.Reset();
  g.composition.Reset();
  if (g.controller) {
    g.controller->Close();
    g.controller.Reset();
  }
  std::atomic_store(&g.capture, std::shared_ptr<VisualCapture>());
}

}  // namespace slimm_youtube

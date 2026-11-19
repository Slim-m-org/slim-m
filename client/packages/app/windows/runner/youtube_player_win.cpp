// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_win.h"

#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <wrl.h>

#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>

#include <memory>
#include <utility>

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
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> webview;
  std::string html;
  MessageHandler on_message;
  RECT bounds = {0, 0, 0, 0};
  bool visible = false;
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

void Apply() {
  if (!g.controller) return;
  RECT rect = g.bounds;
  if (g.fullscreen) GetClientRect(g.parent, &rect);
  g.controller->put_Bounds(rect);
  bool show = g.fullscreen ||
              (g.visible && rect.right > rect.left && rect.bottom > rect.top);
  g.controller->put_IsVisible(show ? TRUE : FALSE);
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

void OnController(int generation, ICoreWebView2Controller* controller,
                  const std::function<void(bool)>& done) {
  if (generation != g.generation || controller == nullptr) {
    if (controller != nullptr) controller->Close();
    done(false);
    return;
  }
  g.controller = controller;
  g.controller->get_CoreWebView2(&g.webview);
  ComPtr<ICoreWebView2Controller2> controller2;
  if (SUCCEEDED(g.controller.As(&controller2))) {
    COREWEBVIEW2_COLOR black = {255, 0, 0, 0};
    controller2->put_DefaultBackgroundColor(black);
  }
  Configure(g.webview.Get());
  Wire(g.webview.Get());
  Apply();
  g.webview->Navigate(kHostUrl);
  done(true);
}

void CreateController(int generation, std::function<void(bool)> done) {
  auto completed =
      Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
          [generation, done](HRESULT result,
                             ICoreWebView2Controller* controller) {
            OnController(generation, SUCCEEDED(result) ? controller : nullptr,
                         done);
            return S_OK;
          });
  ComPtr<ICoreWebView2Environment10> environment10;
  ComPtr<ICoreWebView2ControllerOptions> options;
  if (SUCCEEDED(g.environment.As(&environment10)) &&
      SUCCEEDED(environment10->CreateCoreWebView2ControllerOptions(&options))) {
    // Nothing the player stores outlives it, in keeping with youtube-nocookie.
    options->put_IsInPrivateModeEnabled(TRUE);
    if (SUCCEEDED(environment10->CreateCoreWebView2ControllerWithOptions(
            g.parent, options.Get(), completed.Get()))) {
      return;
    }
  }
  if (FAILED(g.environment->CreateCoreWebView2Controller(g.parent,
                                                         completed.Get()))) {
    done(false);
  }
}

}  // namespace

bool RuntimeAvailable() {
  LPWSTR version = nullptr;
  HRESULT result = GetAvailableCoreWebView2BrowserVersionString(nullptr, &version);
  bool available = SUCCEEDED(result) && version != nullptr;
  CoTaskMemFree(version);
  return available;
}

void Create(HWND parent, const std::string& html, MessageHandler on_message,
            std::function<void(bool)> done) {
  Destroy();
  g.parent = parent;
  g.html = html;
  g.on_message = std::move(on_message);
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

void SetBounds(RECT physical) {
  g.bounds = physical;
  Apply();
}

void SetVisible(bool visible) {
  g.visible = visible;
  Apply();
}

void Run(const std::string& script) {
  if (g.webview) g.webview->ExecuteScript(Wide(script).c_str(), nullptr);
}

void Destroy() {
  g.generation++;
  g.fullscreen = false;
  g.visible = false;
  g.webview.Reset();
  if (g.controller) {
    g.controller->Close();
    g.controller.Reset();
  }
}

}  // namespace slimm_youtube

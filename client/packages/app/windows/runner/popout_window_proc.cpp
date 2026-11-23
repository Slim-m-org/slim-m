// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "popout_window_proc.h"

namespace {

// The pop-out's smallest content in logical pixels, as _minSize in popout_windowing_win32.dart.
constexpr double kMinWidth = 240;
constexpr double kMinHeight = 160;

// The engine's view window class; window_manager looks it up by the same name.
constexpr wchar_t kViewWindowClass[] = L"FLUTTERVIEW";

/// Sizes the Flutter view to the client area, as the engine's own window
/// does; empty when there is no view to size, so the engine handles it.
std::optional<LRESULT> FitContentToClient(HWND window) {
  const HWND content =
      ::FindWindowExW(window, nullptr, kViewWindowClass, nullptr);
  if (content == nullptr) return std::nullopt;
  RECT client;
  ::GetClientRect(window, &client);
  ::MoveWindow(content, client.left, client.top, client.right - client.left,
               client.bottom - client.top, TRUE);
  return 0;
}

LRESULT FollowDpiChange(HWND window, LPARAM lparam) {
  const auto* suggested = reinterpret_cast<const RECT*>(lparam);
  ::SetWindowPos(window, nullptr, suggested->left, suggested->top,
                 suggested->right - suggested->left,
                 suggested->bottom - suggested->top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
  return 0;
}

LRESULT KeepMinimumSize(HWND window, LPARAM lparam) {
  RECT frame;
  RECT client;
  ::GetWindowRect(window, &frame);
  ::GetClientRect(window, &client);
  const double scale =
      static_cast<double>(::GetDpiForWindow(window)) / USER_DEFAULT_SCREEN_DPI;
  auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
  info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale) +
                           (frame.right - frame.left) -
                           (client.right - client.left);
  info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale) +
                           (frame.bottom - frame.top) -
                           (client.bottom - client.top);
  return 0;
}

}  // namespace

std::optional<LRESULT> HandlePopOutMessage(HWND window, UINT message,
                                           WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_SIZE:
      return FitContentToClient(window);
    case WM_DPICHANGED:
      return FollowDpiChange(window, lparam);
    case WM_GETMINMAXINFO:
      return KeepMinimumSize(window, lparam);
    case WM_NCCALCSIZE:
    case WM_NCHITTEST:
    case WM_NCACTIVATE:
    case WM_SIZING:
    case WM_MOVING:
    case WM_EXITSIZEMOVE:
    case WM_SHOWWINDOW:
      return ::DefWindowProcW(window, message, wparam, lparam);
    default:
      return std::nullopt;
  }
}

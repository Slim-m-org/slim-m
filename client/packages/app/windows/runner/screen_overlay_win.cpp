#include "screen_overlay_win.h"

#include "screen_overlay_win_capture.h"
#include "screen_overlay_win_panel.h"

#include <windows.h>

#include <dwmapi.h>

#include <algorithm>
#include <cmath>
#include <memory>

// gdiplus.h needs the min and max macros the runner turns off.
using std::max;
using std::min;
#include <gdiplus.h>

namespace slimm_overlay {
namespace {

// Not in older SDK headers; Windows 10 version 2004 added it.
constexpr DWORD kExcludeFromCapture = 0x00000011;
constexpr DWORD kMinBuildForExclude = 19041;
constexpr wchar_t kClassName[] = L"SlimmScreenOverlayWindow";
// The share picker hides windows with this title (ownOverlayWindowTitle in the rtc package).
constexpr wchar_t kWindowTitle[] = L"slim-m screen overlay";
constexpr double kNoteRadius = 6;
constexpr double kNotePad = 8;
constexpr double kNoteMaxWidth = 260;

// One click-through window over one monitor, with its own surface: the drawing overlay and the call panel are separate so each can sit on its own monitor.
struct Layer {
  HWND window = nullptr;
  int monitor = 0;
  int width = 0;
  int height = 0;
  // One premultiplied surface for the window's life: a fresh full-monitor bitmap and copy per frame stalled the first marks.
  HDC surface_dc = nullptr;
  HBITMAP surface = nullptr;
  HGDIOBJ surface_previous = nullptr;
  void* surface_bits = nullptr;
};

Layer g_draw;
Layer g_panel_layer;
ULONG_PTR g_gdiplus_token = 0;
bool g_class_registered = false;
std::vector<Shape> g_shapes;
Panel g_panel;
// The shared window the drawing overlay follows, or null when it covers a monitor.
HWND g_target = nullptr;
std::vector<HWINEVENTHOOK> g_hooks;

bool BuildSupportsExclude() {
  using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return false;
  auto get_version = reinterpret_cast<RtlGetVersionFn>(
      reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion")));
  if (get_version == nullptr) return false;
  OSVERSIONINFOW info = {};
  info.dwOSVersionInfoSize = sizeof(info);
  if (get_version(&info) != 0) return false;
  return info.dwMajorVersion > 10 ||
         (info.dwMajorVersion == 10 && info.dwBuildNumber >= kMinBuildForExclude);
}

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* out = reinterpret_cast<std::vector<Monitor>*>(data);
  MONITORINFOEXW info = {};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&info))) return TRUE;
  Monitor m;
  m.device = info.szDevice;
  m.x = info.rcMonitor.left;
  m.y = info.rcMonitor.top;
  m.width = info.rcMonitor.right - info.rcMonitor.left;
  m.height = info.rcMonitor.bottom - info.rcMonitor.top;
  m.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
  out->push_back(m);
  return TRUE;
}

std::vector<Monitor> Monitors() {
  std::vector<Monitor> monitors;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&monitors));
  return monitors;
}

Gdiplus::Color ColorOf(uint32_t argb, double alpha) {
  double a = alpha * static_cast<double>((argb >> 24) & 0xFF);
  return Gdiplus::Color(static_cast<BYTE>(std::clamp(a, 0.0, 255.0)),
                        static_cast<BYTE>((argb >> 16) & 0xFF),
                        static_cast<BYTE>((argb >> 8) & 0xFF),
                        static_cast<BYTE>(argb & 0xFF));
}

void DrawStroke(Gdiplus::Graphics& g, const Shape& s, double w, double h) {
  if (s.points.size() < 4) return;
  Gdiplus::Pen pen(ColorOf(s.argb, s.alpha), static_cast<Gdiplus::REAL>(s.width));
  pen.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
  pen.SetLineJoin(Gdiplus::LineJoinRound);
  std::vector<Gdiplus::PointF> pts;
  for (size_t i = 0; i + 1 < s.points.size(); i += 2) {
    pts.emplace_back(static_cast<Gdiplus::REAL>(s.points[i] * w),
                     static_cast<Gdiplus::REAL>(s.points[i + 1] * h));
  }
  g.DrawLines(&pen, pts.data(), static_cast<INT>(pts.size()));
}

void DrawEllipse(Gdiplus::Graphics& g, const Shape& s, double w, double h) {
  if (s.points.size() != 4) return;
  double x0 = std::min(s.points[0], s.points[2]) * w;
  double x1 = std::max(s.points[0], s.points[2]) * w;
  double y0 = std::min(s.points[1], s.points[3]) * h;
  double y1 = std::max(s.points[1], s.points[3]) * h;
  if (x1 - x0 < 1 || y1 - y0 < 1) return;
  Gdiplus::Pen pen(ColorOf(s.argb, s.alpha), static_cast<Gdiplus::REAL>(s.width));
  g.DrawEllipse(&pen, static_cast<Gdiplus::REAL>(x0), static_cast<Gdiplus::REAL>(y0),
                static_cast<Gdiplus::REAL>(x1 - x0), static_cast<Gdiplus::REAL>(y1 - y0));
}

void AddRoundedRect(Gdiplus::GraphicsPath& path, double x, double y, double w,
                    double h, double r) {
  const Gdiplus::REAL d = static_cast<Gdiplus::REAL>(r * 2);
  const Gdiplus::REAL fx = static_cast<Gdiplus::REAL>(x);
  const Gdiplus::REAL fy = static_cast<Gdiplus::REAL>(y);
  const Gdiplus::REAL fw = static_cast<Gdiplus::REAL>(w);
  const Gdiplus::REAL fh = static_cast<Gdiplus::REAL>(h);
  path.AddArc(fx, fy, d, d, 180, 90);
  path.AddArc(fx + fw - d, fy, d, d, 270, 90);
  path.AddArc(fx + fw - d, fy + fh - d, d, d, 0, 90);
  path.AddArc(fx, fy + fh - d, d, d, 90, 90);
  path.CloseFigure();
}

void DrawNote(Gdiplus::Graphics& g, const Shape& s, double w, double h) {
  if (s.points.size() != 2 || s.text.empty()) return;
  Gdiplus::FontFamily family(L"Segoe UI");
  Gdiplus::Font font(&family, 13, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
  Gdiplus::RectF limit(0, 0, static_cast<Gdiplus::REAL>(kNoteMaxWidth), 0);
  Gdiplus::RectF bounds;
  g.MeasureString(s.text.c_str(), -1, &font, limit, &bounds);
  double bw = bounds.Width + 2 * kNotePad;
  double bh = bounds.Height + 2 * kNotePad;
  double x = std::max(0.0, std::min(s.points[0] * w, w - bw));
  double y = std::max(0.0, std::min(s.points[1] * h, h - bh));
  Gdiplus::GraphicsPath path;
  AddRoundedRect(path, x, y, bw, bh, kNoteRadius);
  Gdiplus::SolidBrush fill(ColorOf(s.argb, s.alpha));
  g.FillPath(&fill, &path);
  Gdiplus::SolidBrush ink(ColorOf(0xFF1A1A1A, s.alpha));
  Gdiplus::RectF at(static_cast<Gdiplus::REAL>(x + kNotePad),
                    static_cast<Gdiplus::REAL>(y + kNotePad),
                    static_cast<Gdiplus::REAL>(kNoteMaxWidth), 0);
  g.DrawString(s.text.c_str(), -1, &font, at, nullptr, &ink);
}

void ReleaseSurface(Layer& layer) {
  if (layer.surface_dc != nullptr) {
    SelectObject(layer.surface_dc, layer.surface_previous);
    DeleteDC(layer.surface_dc);
  }
  if (layer.surface != nullptr) DeleteObject(layer.surface);
  layer.surface_dc = nullptr;
  layer.surface = nullptr;
  layer.surface_previous = nullptr;
  layer.surface_bits = nullptr;
}

bool EnsureSurface(Layer& layer) {
  if (layer.surface != nullptr) return true;
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = layer.width;
  info.bmiHeader.biHeight = -layer.height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC screen = GetDC(nullptr);
  layer.surface = CreateDIBSection(screen, &info, DIB_RGB_COLORS,
                                   &layer.surface_bits, nullptr, 0);
  if (layer.surface != nullptr) layer.surface_dc = CreateCompatibleDC(screen);
  ReleaseDC(nullptr, screen);
  if (layer.surface == nullptr || layer.surface_dc == nullptr) {
    ReleaseSurface(layer);
    return false;
  }
  layer.surface_previous = SelectObject(layer.surface_dc, layer.surface);
  return true;
}

enum class Content { kShapes, kPanel };

// Renders the layer's content straight into its surface and hands it to the layered window.
void Present(Layer& layer, Content content) {
  if (layer.window == nullptr || layer.width <= 0 || layer.height <= 0) return;
  if (!EnsureSurface(layer)) return;
  {
    Gdiplus::Bitmap bitmap(layer.width, layer.height, layer.width * 4,
                           PixelFormat32bppPARGB,
                           static_cast<BYTE*>(layer.surface_bits));
    Gdiplus::Graphics g(&bitmap);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    g.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    g.SetCompositingMode(Gdiplus::CompositingModeSourceOver);
    if (content == Content::kShapes) {
      for (const Shape& s : g_shapes) {
        switch (s.kind) {
          case Shape::Kind::kStroke: DrawStroke(g, s, layer.width, layer.height); break;
          case Shape::Kind::kEllipse: DrawEllipse(g, s, layer.width, layer.height); break;
          case Shape::Kind::kNote: DrawNote(g, s, layer.width, layer.height); break;
        }
      }
    } else if (g_panel.present) {
      double scale = static_cast<double>(GetDpiForWindow(layer.window)) / 96.0;
      DrawPanel(g, g_panel, layer.width, layer.height, scale > 0 ? scale : 1.0);
    }
  }
  GdiFlush();
  HDC screen = GetDC(nullptr);
  POINT origin = {0, 0};
  SIZE size = {layer.width, layer.height};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(layer.window, screen, nullptr, &size, layer.surface_dc,
                      &origin, 0, &blend, ULW_ALPHA);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK OverlayProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_DESTROY:
      if (hwnd == g_draw.window) g_draw.window = nullptr;
      if (hwnd == g_panel_layer.window) g_panel_layer.window = nullptr;
      return 0;
    default:
      return DefWindowProcW(hwnd, message, wparam, lparam);
  }
}

bool EnsureClass() {
  if (g_class_registered) return true;
  WNDCLASSW wc = {};
  wc.lpfnWndProc = OverlayProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  if (RegisterClassW(&wc) == 0) return false;
  g_class_registered = true;
  return true;
}

bool EnsureGdiplus() {
  if (g_gdiplus_token != 0) return true;
  Gdiplus::GdiplusStartupInput input;
  return Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr) == Gdiplus::Ok;
}

// Opens a click-through window over [monitor] and hides it from capture; refused means it would show up in the share, so it is not shown at all.
bool OpenLayer(Layer& layer, const Monitor& m, size_t index) {
  if (!BuildSupportsExclude() || !EnsureClass() || !EnsureGdiplus()) return false;
  HWND window = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE |
          WS_EX_TOOLWINDOW,
      kClassName, kWindowTitle, WS_POPUP, m.x, m.y, m.width, m.height,
      nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (window == nullptr) return false;
  if (!SetWindowDisplayAffinity(window, kExcludeFromCapture)) {
    DestroyWindow(window);
    return false;
  }
  layer.window = window;
  layer.monitor = static_cast<int>(index);
  layer.width = m.width;
  layer.height = m.height;
  return true;
}

void RevealLayer(Layer& layer, Content content) {
  Present(layer, content);
  ShowWindow(layer.window, SW_SHOWNOACTIVATE);
  SetWindowPos(layer.window, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void CloseLayer(Layer& layer) {
  if (layer.window != nullptr) {
    HWND window = layer.window;
    layer.window = nullptr;
    DestroyWindow(window);
  }
  ReleaseSurface(layer);
}

size_t MonitorIndex(const std::vector<Monitor>& monitors, int requested) {
  return requested >= 0 && static_cast<size_t>(requested) < monitors.size()
             ? static_cast<size_t>(requested)
             : 0;
}

// The window as the capturer sees it: the visible frame, without the invisible resize border.
bool WindowBounds(HWND window, RECT* bounds) {
  if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, bounds,
                                   sizeof(RECT))) &&
      !GetWindowRect(window, bounds)) {
    return false;
  }
  return bounds->right > bounds->left && bounds->bottom > bounds->top;
}

// Puts the overlay back over the shared window, or hides it while the window is minimized, hidden or gone.
void FollowTarget() {
  if (g_draw.window == nullptr || g_target == nullptr) return;
  RECT bounds = {};
  if (!IsWindow(g_target) || IsIconic(g_target) || !IsWindowVisible(g_target) ||
      !WindowBounds(g_target, &bounds)) {
    ShowWindow(g_draw.window, SW_HIDE);
    return;
  }
  int width = bounds.right - bounds.left;
  int height = bounds.bottom - bounds.top;
  bool resized = width != g_draw.width || height != g_draw.height;
  if (resized) {
    ReleaseSurface(g_draw);
    g_draw.width = width;
    g_draw.height = height;
  }
  SetWindowPos(g_draw.window, HWND_TOPMOST, bounds.left, bounds.top, width, height,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  if (resized) Present(g_draw, Content::kShapes);
}

void CALLBACK OnTargetEvent(HWINEVENTHOOK, DWORD, HWND window, LONG object, LONG,
                            DWORD, DWORD) {
  if (window == g_target && object == OBJID_WINDOW) FollowTarget();
}

void StopFollowing() {
  for (HWINEVENTHOOK hook : g_hooks) UnhookWinEvent(hook);
  g_hooks.clear();
  g_target = nullptr;
}

void FollowEvents(DWORD first, DWORD last) {
  DWORD thread = GetWindowThreadProcessId(g_target, nullptr);
  HWINEVENTHOOK hook = SetWinEventHook(first, last, nullptr, OnTargetEvent, 0,
                                       thread, WINEVENT_OUTOFCONTEXT);
  if (hook != nullptr) g_hooks.push_back(hook);
}

}  // namespace

bool Supported(std::vector<Monitor>* monitors) {
  if (!BuildSupportsExclude()) return false;
  *monitors = Monitors();
  AssignCaptureOrder(monitors);
  return !monitors->empty();
}

bool Show(int monitor_index) {
  Hide();
  std::vector<Monitor> monitors = Monitors();
  if (monitors.empty()) return false;
  size_t index = MonitorIndex(monitors, monitor_index);
  if (!OpenLayer(g_draw, monitors[index], index)) return false;
  g_shapes.clear();
  RevealLayer(g_draw, Content::kShapes);
  return true;
}

bool ShowOverWindow(int64_t handle) {
  Hide();
  HWND target = reinterpret_cast<HWND>(static_cast<intptr_t>(handle));
  RECT bounds = {};
  if (!IsWindow(target) || !WindowBounds(target, &bounds)) return false;
  Monitor area;
  area.x = bounds.left;
  area.y = bounds.top;
  area.width = bounds.right - bounds.left;
  area.height = bounds.bottom - bounds.top;
  if (!OpenLayer(g_draw, area, 0)) return false;
  g_shapes.clear();
  g_target = target;
  RevealLayer(g_draw, Content::kShapes);
  // Destroy through location change covers moves, resizes, shows and hides; the minimize pair is the system's own.
  FollowEvents(EVENT_OBJECT_DESTROY, EVENT_OBJECT_LOCATIONCHANGE);
  FollowEvents(EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND);
  FollowTarget();
  return true;
}

void Draw(std::vector<Shape> shapes) {
  g_shapes = std::move(shapes);
  Present(g_draw, Content::kShapes);
}

void SetPanel(Panel panel) {
  if (!panel.present) {
    g_panel = Panel();
    ForgetAvatars();
    CloseLayer(g_panel_layer);
    return;
  }
  if (g_panel_layer.window != nullptr && g_panel_layer.monitor != panel.monitor) {
    CloseLayer(g_panel_layer);
  }
  if (g_panel_layer.window == nullptr) {
    std::vector<Monitor> monitors = Monitors();
    if (monitors.empty()) return;
    size_t index = MonitorIndex(monitors, panel.monitor);
    if (!OpenLayer(g_panel_layer, monitors[index], index)) return;
    g_panel_layer.monitor = panel.monitor;
    g_panel = std::move(panel);
    CacheAvatars(&g_panel);
    RevealLayer(g_panel_layer, Content::kPanel);
    return;
  }
  g_panel = std::move(panel);
  CacheAvatars(&g_panel);
  Present(g_panel_layer, Content::kPanel);
}

BOOL CALLBACK FindAppWindow(HWND window, LPARAM data) {
  wchar_t name[64] = {};
  GetClassNameW(window, name, 64);
  if (wcscmp(name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
  *reinterpret_cast<HWND*>(data) = window;
  return FALSE;
}

int AppMonitor() {
  HWND app = nullptr;
  EnumThreadWindows(GetCurrentThreadId(), FindAppWindow, reinterpret_cast<LPARAM>(&app));
  if (app == nullptr) return -1;
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  HMONITOR on = MonitorFromWindow(app, MONITOR_DEFAULTTONEAREST);
  if (on == nullptr || !GetMonitorInfoW(on, &info)) return -1;
  std::vector<Monitor> monitors = Monitors();
  for (size_t i = 0; i < monitors.size(); i++) {
    if (monitors[i].x == info.rcMonitor.left && monitors[i].y == info.rcMonitor.top) {
      return static_cast<int>(i);
    }
  }
  return -1;
}

void Hide() {
  StopFollowing();
  g_shapes.clear();
  CloseLayer(g_draw);
}

}  // namespace slimm_overlay

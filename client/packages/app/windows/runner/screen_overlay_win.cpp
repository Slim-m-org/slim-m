#include "screen_overlay_win.h"

#include <windows.h>

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
constexpr double kNoteRadius = 6;
constexpr double kNotePad = 8;
constexpr double kNoteMaxWidth = 260;

HWND g_window = nullptr;
int g_width = 0;
int g_height = 0;
ULONG_PTR g_gdiplus_token = 0;
bool g_class_registered = false;
std::vector<Shape> g_shapes;

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
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return TRUE;
  Monitor m;
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

// Renders the shapes into a premultiplied bitmap and hands it to the layered window.
void Present() {
  if (g_window == nullptr || g_width <= 0 || g_height <= 0) return;
  Gdiplus::Bitmap bitmap(g_width, g_height, PixelFormat32bppPARGB);
  {
    Gdiplus::Graphics g(&bitmap);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));
    for (const Shape& s : g_shapes) {
      switch (s.kind) {
        case Shape::Kind::kStroke: DrawStroke(g, s, g_width, g_height); break;
        case Shape::Kind::kEllipse: DrawEllipse(g, s, g_width, g_height); break;
        case Shape::Kind::kNote: DrawNote(g, s, g_width, g_height); break;
      }
    }
  }
  HBITMAP hbitmap = nullptr;
  if (bitmap.GetHBITMAP(Gdiplus::Color(0, 0, 0, 0), &hbitmap) != Gdiplus::Ok) {
    return;
  }
  HDC screen = GetDC(nullptr);
  HDC memory = CreateCompatibleDC(screen);
  HGDIOBJ previous = SelectObject(memory, hbitmap);
  POINT origin = {0, 0};
  SIZE size = {g_width, g_height};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(g_window, screen, nullptr, &size, memory, &origin, 0,
                      &blend, ULW_ALPHA);
  SelectObject(memory, previous);
  DeleteDC(memory);
  DeleteObject(hbitmap);
  ReleaseDC(nullptr, screen);
}

LRESULT CALLBACK OverlayProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_DESTROY:
      if (hwnd == g_window) g_window = nullptr;
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

}  // namespace

bool Supported(std::vector<Monitor>* monitors) {
  if (!BuildSupportsExclude()) return false;
  *monitors = Monitors();
  return !monitors->empty();
}

bool Show(int monitor_index) {
  Hide();
  if (!BuildSupportsExclude() || !EnsureClass() || !EnsureGdiplus()) return false;
  std::vector<Monitor> monitors = Monitors();
  if (monitors.empty()) return false;
  size_t index = monitor_index >= 0 && static_cast<size_t>(monitor_index) < monitors.size()
                     ? static_cast<size_t>(monitor_index)
                     : 0;
  const Monitor& m = monitors[index];
  HWND window = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE |
          WS_EX_TOOLWINDOW,
      kClassName, L"slim-m screen overlay", WS_POPUP, m.x, m.y, m.width, m.height,
      nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (window == nullptr) return false;
  // Refused means the overlay would show up in the share, so it is not shown at all.
  if (!SetWindowDisplayAffinity(window, kExcludeFromCapture)) {
    DestroyWindow(window);
    return false;
  }
  g_window = window;
  g_width = m.width;
  g_height = m.height;
  g_shapes.clear();
  Present();
  ShowWindow(window, SW_SHOWNOACTIVATE);
  SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return true;
}

void Draw(std::vector<Shape> shapes) {
  g_shapes = std::move(shapes);
  Present();
}

void Hide() {
  g_shapes.clear();
  if (g_window != nullptr) {
    HWND window = g_window;
    g_window = nullptr;
    DestroyWindow(window);
  }
}

}  // namespace slimm_overlay

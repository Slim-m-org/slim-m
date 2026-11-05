#include "screen_overlay_win_panel.h"

#include <cmath>
#include <string>

namespace slimm_overlay {
namespace {

// Sizes follow the 4dp grid and the panel radius of docs/design/design-language.md.
constexpr double kMargin = 16;
constexpr double kPadX = 12;
constexpr double kPadY = 8;
constexpr double kRowHeight = 24;
constexpr double kRadius = 10;
constexpr double kDotBox = 12;
constexpr double kGap = 8;
constexpr double kGlyph = 14;
constexpr double kMaxName = 180;
constexpr double kFontPx = 12;

using Gdiplus::REAL;

Gdiplus::Color ColorOf(uint32_t argb, double alpha = 1) {
  double a = alpha * static_cast<double>((argb >> 24) & 0xFF);
  return Gdiplus::Color(static_cast<BYTE>(std::clamp(a, 0.0, 255.0)),
                        static_cast<BYTE>((argb >> 16) & 0xFF),
                        static_cast<BYTE>((argb >> 8) & 0xFF),
                        static_cast<BYTE>(argb & 0xFF));
}

void AddRoundedRect(Gdiplus::GraphicsPath& path, double x, double y, double w,
                    double h, double r) {
  const REAL d = static_cast<REAL>(r * 2);
  const REAL fx = static_cast<REAL>(x);
  const REAL fy = static_cast<REAL>(y);
  const REAL fw = static_cast<REAL>(w);
  const REAL fh = static_cast<REAL>(h);
  path.AddArc(fx, fy, d, d, 180, 90);
  path.AddArc(fx + fw - d, fy, d, d, 270, 90);
  path.AddArc(fx + fw - d, fy + fh - d, d, d, 0, 90);
  path.AddArc(fx, fy + fh - d, d, d, 90, 90);
  path.CloseFigure();
}

// A name stays on one line and ends in an ellipsis when it is too long.
void ConfigureName(Gdiplus::StringFormat& format) {
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
}

double TextWidth(Gdiplus::Graphics& g, const Gdiplus::Font& font,
                 const std::wstring& text) {
  Gdiplus::RectF limit(0, 0, static_cast<REAL>(kMaxName), static_cast<REAL>(kRowHeight));
  Gdiplus::StringFormat format;
  ConfigureName(format);
  Gdiplus::RectF bounds;
  g.MeasureString(text.c_str(), -1, &font, limit, &format, &bounds);
  return std::min(static_cast<double>(bounds.Width), kMaxName);
}

void DrawText(Gdiplus::Graphics& g, const Gdiplus::Font& font,
              const std::wstring& text, double x, double cy, uint32_t argb) {
  Gdiplus::RectF at(static_cast<REAL>(x), static_cast<REAL>(cy - kRowHeight / 2),
                    static_cast<REAL>(kMaxName), static_cast<REAL>(kRowHeight));
  Gdiplus::StringFormat format;
  ConfigureName(format);
  Gdiplus::SolidBrush ink(ColorOf(argb));
  g.DrawString(text.c_str(), -1, &font, at, &format, &ink);
}

void DrawEllipseAt(Gdiplus::Graphics& g, Gdiplus::Pen* pen, Gdiplus::Brush* fill,
                   double cx, double cy, double r) {
  Gdiplus::RectF box(static_cast<REAL>(cx - r), static_cast<REAL>(cy - r),
                     static_cast<REAL>(2 * r), static_cast<REAL>(2 * r));
  if (fill != nullptr) g.FillEllipse(fill, box);
  if (pen != nullptr) g.DrawEllipse(pen, box);
}

// A lit dot with a soft ring while they talk, a dim dot otherwise.
void DrawPresence(Gdiplus::Graphics& g, const Panel& panel, bool speaking,
                  double cx, double cy) {
  if (speaking) {
    Gdiplus::Pen ring(ColorOf(panel.accent, 0.4), 2);
    DrawEllipseAt(g, &ring, nullptr, cx, cy, 5.5);
    Gdiplus::SolidBrush lit(ColorOf(panel.accent));
    DrawEllipseAt(g, nullptr, &lit, cx, cy, 3.5);
  } else {
    Gdiplus::SolidBrush dim(ColorOf(panel.text_muted, 0.4));
    DrawEllipseAt(g, nullptr, &dim, cx, cy, 3.5);
  }
}

// A microphone, or headphones when deafened, struck through.
void DrawMark(Gdiplus::Graphics& g, const Panel& panel, bool deafened, double cx,
              double cy) {
  Gdiplus::Pen pen(ColorOf(panel.danger), 1.5f);
  pen.SetStartCap(Gdiplus::LineCapRound);
  pen.SetEndCap(Gdiplus::LineCapRound);
  Gdiplus::SolidBrush fill(ColorOf(panel.danger));
  if (deafened) {
    g.DrawArc(&pen, static_cast<REAL>(cx - 5), static_cast<REAL>(cy - 4), 10.0f,
              10.0f, 180, 180);
    g.FillRectangle(&fill, static_cast<REAL>(cx - 6.5), static_cast<REAL>(cy + 1),
                    2.5f, 4.0f);
    g.FillRectangle(&fill, static_cast<REAL>(cx + 4), static_cast<REAL>(cy + 1),
                    2.5f, 4.0f);
  } else {
    Gdiplus::GraphicsPath capsule;
    AddRoundedRect(capsule, cx - 2, cy - 6, 4, 8, 2);
    g.DrawPath(&pen, &capsule);
    g.DrawArc(&pen, static_cast<REAL>(cx - 4.5), static_cast<REAL>(cy - 4.5), 9.0f,
              9.0f, 0, 180);
    g.DrawLine(&pen, static_cast<REAL>(cx), static_cast<REAL>(cy + 4.5),
               static_cast<REAL>(cx), static_cast<REAL>(cy + 6.5));
  }
  g.DrawLine(&pen, static_cast<REAL>(cx - 6), static_cast<REAL>(cy - 6),
             static_cast<REAL>(cx + 6), static_cast<REAL>(cy + 6));
}

}  // namespace

void DrawPanel(Gdiplus::Graphics& g, const Panel& panel, double width,
               double height, double scale) {
  if (!panel.present || panel.rows.empty()) return;
  g.ScaleTransform(static_cast<REAL>(scale), static_cast<REAL>(scale));
  double w = width / scale;
  double h = height / scale;
  Gdiplus::FontFamily family(L"Segoe UI");
  Gdiplus::Font font(&family, static_cast<REAL>(kFontPx), Gdiplus::FontStyleRegular,
                     Gdiplus::UnitPixel);
  bool any_mark = false;
  double name_width = 0;
  for (const PanelRow& row : panel.rows) {
    any_mark = any_mark || row.muted || row.deafened;
    name_width = std::max(name_width, TextWidth(g, font, row.name));
  }
  std::wstring more = panel.more > 0 ? L"+" + std::to_wstring(panel.more) + L" more" : L"";
  if (!more.empty()) name_width = std::max(name_width, TextWidth(g, font, more));
  double marks = any_mark ? kGap + kGlyph : 0;
  double pw = 2 * kPadX + kDotBox + kGap + name_width + marks;
  double lines = static_cast<double>(panel.rows.size()) + (more.empty() ? 0 : 1);
  double ph = 2 * kPadY + lines * kRowHeight;
  bool left = panel.corner == Panel::Corner::kTopLeft ||
              panel.corner == Panel::Corner::kBottomLeft;
  bool top = panel.corner == Panel::Corner::kTopLeft ||
             panel.corner == Panel::Corner::kTopRight;
  double x = left ? kMargin : w - kMargin - pw;
  double y = top ? kMargin : h - kMargin - ph;

  Gdiplus::GraphicsPath shape;
  AddRoundedRect(shape, x + 0.5, y + 0.5, pw - 1, ph - 1, kRadius);
  Gdiplus::SolidBrush surface(ColorOf(panel.surface));
  g.FillPath(&surface, &shape);
  Gdiplus::Pen border(ColorOf(panel.border), 1);
  g.DrawPath(&border, &shape);

  double cy = y + kPadY + kRowHeight / 2;
  for (const PanelRow& row : panel.rows) {
    DrawPresence(g, panel, row.speaking, x + kPadX + kDotBox / 2, cy);
    DrawText(g, font, row.name, x + kPadX + kDotBox + kGap, cy, panel.text);
    if (row.muted || row.deafened) {
      DrawMark(g, panel, row.deafened, x + pw - kPadX - kGlyph / 2, cy);
    }
    cy += kRowHeight;
  }
  if (!more.empty()) {
    DrawText(g, font, more, x + kPadX + kDotBox + kGap, cy, panel.text_muted);
  }
  g.ResetTransform();
}

}  // namespace slimm_overlay

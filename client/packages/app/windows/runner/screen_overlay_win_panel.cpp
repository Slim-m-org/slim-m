#include "screen_overlay_win_panel.h"

#include <shlwapi.h>

#include <cmath>
#include <map>
#include <memory>
#include <string>

namespace slimm_overlay {
namespace {

// Sizes follow the 4dp grid and the panel radius of docs/design/design-language.md.
constexpr double kMargin = 16;
constexpr double kPadX = 8;
constexpr double kPadY = 6;
constexpr double kRowHeight = 28;
constexpr double kRadius = 10;
constexpr double kAvatar = 24;
constexpr double kRing = 2;
// The picture plus its ring, which is as tall as a row so the rings of two rows only touch.
constexpr double kAvatarSlot = kAvatar + 2 * kRing;
constexpr double kGap = 6;
constexpr double kMarkGap = 8;
constexpr double kGlyph = 14;
constexpr double kMaxName = 180;
constexpr double kFontPx = 11;

using Gdiplus::REAL;

// Pictures by user id, decoded from the PNG the app sends once per picture.
std::map<std::string, std::unique_ptr<Gdiplus::Bitmap>> g_avatars;

// A bitmap made from a stream needs the stream for its whole life, so the pixels are copied out and the stream released.
std::unique_ptr<Gdiplus::Bitmap> DecodePicture(const std::vector<uint8_t>& png) {
  IStream* stream = SHCreateMemStream(png.data(), static_cast<UINT>(png.size()));
  if (stream == nullptr) return nullptr;
  std::unique_ptr<Gdiplus::Bitmap> decoded(Gdiplus::Bitmap::FromStream(stream));
  std::unique_ptr<Gdiplus::Bitmap> copy;
  if (decoded != nullptr && decoded->GetLastStatus() == Gdiplus::Ok) {
    INT w = static_cast<INT>(decoded->GetWidth());
    INT h = static_cast<INT>(decoded->GetHeight());
    copy = std::make_unique<Gdiplus::Bitmap>(w, h, PixelFormat32bppPARGB);
    Gdiplus::Graphics g(copy.get());
    g.SetCompositingMode(Gdiplus::CompositingModeSourceCopy);
    g.DrawImage(decoded.get(), 0, 0, w, h);
  }
  decoded.reset();
  stream->Release();
  if (copy != nullptr && copy->GetLastStatus() != Gdiplus::Ok) return nullptr;
  return copy;
}

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

// Their picture as a circle, ringed in the accent colour while they talk.
void DrawAvatar(Gdiplus::Graphics& g, const Panel& panel, const PanelRow& row,
                double cx, double cy) {
  auto found = g_avatars.find(row.id);
  if (found == g_avatars.end()) {
    Gdiplus::SolidBrush dim(ColorOf(panel.text_muted, 0.4));
    DrawEllipseAt(g, nullptr, &dim, cx, cy, kAvatar / 2);
  } else {
    Gdiplus::InterpolationMode before = g.GetInterpolationMode();
    Gdiplus::PixelOffsetMode offset = g.GetPixelOffsetMode();
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    // Without the half-pixel offset a downscale leaves a faint line on the top and left edges.
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    g.DrawImage(found->second.get(),
                Gdiplus::RectF(static_cast<REAL>(cx - kAvatar / 2),
                               static_cast<REAL>(cy - kAvatar / 2),
                               static_cast<REAL>(kAvatar), static_cast<REAL>(kAvatar)));
    g.SetInterpolationMode(before);
    g.SetPixelOffsetMode(offset);
  }
  if (!row.speaking) return;
  Gdiplus::Pen ring(ColorOf(panel.accent), static_cast<REAL>(kRing));
  DrawEllipseAt(g, &ring, nullptr, cx, cy, kAvatar / 2 + kRing / 2);
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

void CacheAvatars(Panel* panel) {
  for (PanelRow& row : panel->rows) {
    if (row.avatar.empty()) continue;
    std::unique_ptr<Gdiplus::Bitmap> decoded = DecodePicture(row.avatar);
    row.avatar.clear();
    if (decoded == nullptr) {
      g_avatars.erase(row.id);
    } else {
      g_avatars[row.id] = std::move(decoded);
    }
  }
}

void ForgetAvatars() { g_avatars.clear(); }

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
  double marks = any_mark ? kMarkGap + kGlyph : 0;
  double pw = 2 * kPadX + kAvatarSlot + kGap + name_width + marks;
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
    DrawAvatar(g, panel, row, x + kPadX + kAvatarSlot / 2, cy);
    DrawText(g, font, row.name, x + kPadX + kAvatarSlot + kGap, cy, panel.text);
    if (row.muted || row.deafened) {
      DrawMark(g, panel, row.deafened, x + pw - kPadX - kGlyph / 2, cy);
    }
    cy += kRowHeight;
  }
  if (!more.empty()) {
    DrawText(g, font, more, x + kPadX + kAvatarSlot + kGap, cy, panel.text_muted);
  }
  g.ResetTransform();
}

}  // namespace slimm_overlay

#include "screen_overlay_win_stamps.h"

#include <map>
#include <string>

namespace slimm_overlay {
namespace {

// The app sends at most 512 px; anything past these limits did not come from it.
constexpr size_t kMaxPngBytes = 4 * 1024 * 1024;
constexpr UINT kMaxSide = 1024;

using Gdiplus::REAL;

std::map<std::string, std::unique_ptr<Gdiplus::Bitmap>> g_stamps;

}  // namespace

bool PutStampImage(const std::string& key, const std::vector<uint8_t>& png) {
  if (key.empty() || png.size() > kMaxPngBytes || !EnsureGdiplus()) return false;
  std::unique_ptr<Gdiplus::Bitmap> decoded = DecodePicture(png);
  if (decoded == nullptr) return false;
  UINT w = decoded->GetWidth();
  UINT h = decoded->GetHeight();
  if (w == 0 || h == 0 || w > kMaxSide || h > kMaxSide) return false;
  g_stamps[key] = std::move(decoded);
  return true;
}

void DropStampImage(const std::string& key) { g_stamps.erase(key); }

void ForgetStampImages() { g_stamps.clear(); }

void DrawStamp(Gdiplus::Graphics& g, const Shape& s, double width, double height) {
  auto found = g_stamps.find(s.image);
  if (found == g_stamps.end() || s.points.size() != 2 || s.size <= 0) return;
  Gdiplus::Bitmap* bmp = found->second.get();
  double iw = static_cast<double>(bmp->GetWidth());
  double ih = static_cast<double>(bmp->GetHeight());
  double k = s.size * height / std::max(iw, ih);
  double dw = iw * k, dh = ih * k;
  // Clamped with the settled size, so the pop-in never shifts the stamp.
  double cx = std::clamp(s.points[0] * width, std::min(dw / 2, width / 2),
                         std::max(width - dw / 2, width / 2));
  double cy = std::clamp(s.points[1] * height, std::min(dh / 2, height / 2),
                         std::max(height - dh / 2, height / 2));
  double scale = std::clamp(s.scale, 0.0, 2.0);
  double sw = dw * scale, sh = dh * scale;
  if (sw <= 0 || sh <= 0) return;
  REAL alpha = static_cast<REAL>(std::clamp(s.alpha, 0.0, 1.0));
  Gdiplus::GraphicsState state = g.Save();
  g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
  Gdiplus::ColorMatrix matrix = {{{1, 0, 0, 0, 0},
                                  {0, 1, 0, 0, 0},
                                  {0, 0, 1, 0, 0},
                                  {0, 0, 0, alpha, 0},
                                  {0, 0, 0, 0, 1}}};
  Gdiplus::ImageAttributes attrs;
  attrs.SetColorMatrix(&matrix, Gdiplus::ColorMatrixFlagsDefault,
                       Gdiplus::ColorAdjustTypeBitmap);
  g.DrawImage(bmp,
              Gdiplus::RectF(static_cast<REAL>(cx - sw / 2), static_cast<REAL>(cy - sh / 2),
                             static_cast<REAL>(sw), static_cast<REAL>(sh)),
              0, 0, static_cast<REAL>(iw), static_cast<REAL>(ih), Gdiplus::UnitPixel,
              &attrs);
  g.Restore(state);
}

}  // namespace slimm_overlay

#include "screen_overlay_win_png.h"

#include <shlwapi.h>

namespace slimm_overlay {
namespace {

ULONG_PTR g_gdiplus_token = 0;

}  // namespace

bool EnsureGdiplus() {
  if (g_gdiplus_token != 0) return true;
  Gdiplus::GdiplusStartupInput input;
  return Gdiplus::GdiplusStartup(&g_gdiplus_token, &input, nullptr) == Gdiplus::Ok;
}

// A bitmap made from a stream needs the stream for its whole life, so the pixels are copied out and the stream released.
std::unique_ptr<Gdiplus::Bitmap> DecodePicture(const std::vector<uint8_t>& png) {
  if (png.empty()) return nullptr;
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

}  // namespace slimm_overlay

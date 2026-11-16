// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "screen_overlay_stamps.h"

#include <algorithm>
#include <map>

#include "screen_overlay_png.h"

namespace slimm_overlay {
namespace {

// The app sends at most 512 px; anything past these limits did not come from it.
constexpr size_t kMaxPngBytes = 4 * 1024 * 1024;
constexpr int kMaxSide = 1024;

std::map<std::string, cairo_surface_t*> g_stamps;

}  // namespace

bool PutStampImage(const std::string& key, const std::vector<uint8_t>& png) {
  if (key.empty() || png.size() > kMaxPngBytes) return false;
  cairo_surface_t* decoded = DecodePng(png);
  if (decoded == nullptr) return false;
  int w = cairo_image_surface_get_width(decoded);
  int h = cairo_image_surface_get_height(decoded);
  if (w <= 0 || h <= 0 || w > kMaxSide || h > kMaxSide) {
    cairo_surface_destroy(decoded);
    return false;
  }
  DropStampImage(key);
  g_stamps[key] = decoded;
  return true;
}

void DropStampImage(const std::string& key) {
  auto held = g_stamps.find(key);
  if (held == g_stamps.end()) return;
  cairo_surface_destroy(held->second);
  g_stamps.erase(held);
}

void ForgetStampImages() {
  for (auto& entry : g_stamps) cairo_surface_destroy(entry.second);
  g_stamps.clear();
}

void DrawStamp(cairo_t* cr, const Shape& s, double w, double h) {
  auto found = g_stamps.find(s.image);
  if (found == g_stamps.end() || s.points.size() != 2 || s.size <= 0) return;
  cairo_surface_t* img = found->second;
  double iw = cairo_image_surface_get_width(img);
  double ih = cairo_image_surface_get_height(img);
  double k = s.size * h / std::max(iw, ih);
  double dw = iw * k, dh = ih * k;
  // Clamped with the settled size, so the pop-in never shifts the stamp.
  double cx = std::clamp(s.points[0] * w, std::min(dw / 2, w / 2), std::max(w - dw / 2, w / 2));
  double cy = std::clamp(s.points[1] * h, std::min(dh / 2, h / 2), std::max(h - dh / 2, h / 2));
  double ks = k * std::clamp(s.scale, 0.0, 2.0);
  if (ks <= 0) return;
  cairo_save(cr);
  cairo_new_path(cr);
  cairo_translate(cr, cx, cy);
  cairo_scale(cr, ks, ks);
  cairo_set_source_surface(cr, img, -iw / 2, -ih / 2);
  cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_GOOD);
  cairo_rectangle(cr, -iw / 2, -ih / 2, iw, ih);
  cairo_clip(cr);
  cairo_paint_with_alpha(cr, std::clamp(s.alpha, 0.0, 1.0));
  cairo_restore(cr);
}

}  // namespace slimm_overlay

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "screen_overlay_panel.h"

#include <glib.h>
#include <pango/pangocairo.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <string>
#include <vector>

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

// Pictures by user id, decoded from the PNG the app sends once per picture.
std::map<std::string, cairo_surface_t*> g_avatars;

struct PngSource {
  const std::vector<uint8_t>* bytes;
  size_t offset;
};

cairo_status_t ReadPng(void* closure, unsigned char* data, unsigned int length) {
  PngSource* source = static_cast<PngSource*>(closure);
  if (source->offset + length > source->bytes->size()) {
    return CAIRO_STATUS_READ_ERROR;
  }
  memcpy(data, source->bytes->data() + source->offset, length);
  source->offset += length;
  return CAIRO_STATUS_SUCCESS;
}

void SetColor(cairo_t* cr, uint32_t argb, double alpha = 1) {
  cairo_set_source_rgba(cr, ((argb >> 16) & 0xFF) / 255.0,
                        ((argb >> 8) & 0xFF) / 255.0, (argb & 0xFF) / 255.0,
                        alpha * (((argb >> 24) & 0xFF) / 255.0));
}

void RoundedRect(cairo_t* cr, double x, double y, double w, double h, double r) {
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
  cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
  cairo_close_path(cr);
}

PangoLayout* TextLayout(cairo_t* cr, const std::string& text, double max_width) {
  PangoLayout* layout = pango_cairo_create_layout(cr);
  PangoFontDescription* font = pango_font_description_from_string("Sans");
  pango_font_description_set_absolute_size(font, kFontPx * PANGO_SCALE);
  pango_layout_set_font_description(layout, font);
  pango_font_description_free(font);
  pango_layout_set_text(layout, text.c_str(), -1);
  if (max_width > 0) {
    pango_layout_set_width(layout, static_cast<int>(max_width * PANGO_SCALE));
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
  }
  return layout;
}

double TextWidth(cairo_t* cr, const std::string& text, double max_width) {
  PangoLayout* layout = TextLayout(cr, text, max_width);
  int tw = 0, th = 0;
  pango_layout_get_pixel_size(layout, &tw, &th);
  g_object_unref(layout);
  return tw;
}

void DrawText(cairo_t* cr, const std::string& text, double x, double cy,
              double max_width, uint32_t argb) {
  PangoLayout* layout = TextLayout(cr, text, max_width);
  int tw = 0, th = 0;
  pango_layout_get_pixel_size(layout, &tw, &th);
  SetColor(cr, argb);
  cairo_move_to(cr, x, cy - th / 2.0);
  pango_cairo_show_layout(cr, layout);
  g_object_unref(layout);
}

// Their picture as a circle, ringed in the accent colour while they talk.
void DrawAvatar(cairo_t* cr, const Panel& panel, const PanelRow& row, double cx,
                double cy) {
  cairo_new_path(cr);
  auto found = g_avatars.find(row.id);
  if (found == g_avatars.end()) {
    SetColor(cr, panel.text_muted, 0.4);
    cairo_arc(cr, cx, cy, kAvatar / 2, 0, 2 * G_PI);
    cairo_fill(cr);
  } else {
    cairo_surface_t* picture = found->second;
    cairo_save(cr);
    cairo_translate(cr, cx - kAvatar / 2, cy - kAvatar / 2);
    cairo_scale(cr, kAvatar / cairo_image_surface_get_width(picture),
                kAvatar / cairo_image_surface_get_height(picture));
    cairo_set_source_surface(cr, picture, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST);
    cairo_paint(cr);
    cairo_restore(cr);
  }
  if (!row.speaking) return;
  cairo_new_path(cr);
  SetColor(cr, panel.accent);
  cairo_set_line_width(cr, kRing);
  cairo_arc(cr, cx, cy, kAvatar / 2 + kRing / 2, 0, 2 * G_PI);
  cairo_stroke(cr);
}

// A microphone, or headphones when deafened, struck through.
void DrawMark(cairo_t* cr, const Panel& panel, bool deafened, double cx,
              double cy) {
  cairo_new_path(cr);
  SetColor(cr, panel.danger);
  cairo_set_line_width(cr, 1.5);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  if (deafened) {
    cairo_arc(cr, cx, cy + 1, 5, G_PI, 2 * G_PI);
    cairo_stroke(cr);
    cairo_rectangle(cr, cx - 6.5, cy + 1, 2.5, 4);
    cairo_rectangle(cr, cx + 4, cy + 1, 2.5, 4);
    cairo_fill(cr);
  } else {
    RoundedRect(cr, cx - 2, cy - 6, 4, 8, 2);
    cairo_stroke(cr);
    cairo_arc(cr, cx, cy, 4.5, 0, G_PI);
    cairo_stroke(cr);
    cairo_move_to(cr, cx, cy + 4.5);
    cairo_line_to(cr, cx, cy + 6.5);
    cairo_stroke(cr);
  }
  cairo_move_to(cr, cx - 6, cy - 6);
  cairo_line_to(cr, cx + 6, cy + 6);
  cairo_stroke(cr);
}

}  // namespace

void CacheAvatars(Panel* panel) {
  for (PanelRow& row : panel->rows) {
    if (row.avatar.empty()) continue;
    PngSource source = {&row.avatar, 0};
    cairo_surface_t* decoded =
        cairo_image_surface_create_from_png_stream(ReadPng, &source);
    row.avatar.clear();
    auto held = g_avatars.find(row.id);
    if (held != g_avatars.end()) {
      cairo_surface_destroy(held->second);
      g_avatars.erase(held);
    }
    if (cairo_surface_status(decoded) != CAIRO_STATUS_SUCCESS) {
      cairo_surface_destroy(decoded);
      continue;
    }
    g_avatars[row.id] = decoded;
  }
}

void ForgetAvatars() {
  for (auto& entry : g_avatars) cairo_surface_destroy(entry.second);
  g_avatars.clear();
}

void DrawPanel(cairo_t* cr, const Panel& panel, double w, double h) {
  if (!panel.present || panel.rows.empty()) return;
  bool any_mark = false;
  double name_width = 0;
  for (const PanelRow& row : panel.rows) {
    any_mark = any_mark || row.muted || row.deafened;
    name_width = std::fmax(name_width, TextWidth(cr, row.name, kMaxName));
  }
  std::string more = panel.more > 0 ? "+" + std::to_string(panel.more) + " more" : "";
  if (!more.empty()) name_width = std::fmax(name_width, TextWidth(cr, more, kMaxName));
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

  RoundedRect(cr, x + 0.5, y + 0.5, pw - 1, ph - 1, kRadius);
  SetColor(cr, panel.surface);
  cairo_fill_preserve(cr);
  SetColor(cr, panel.border);
  cairo_set_line_width(cr, 1);
  cairo_stroke(cr);

  double cy = y + kPadY + kRowHeight / 2;
  for (const PanelRow& row : panel.rows) {
    DrawAvatar(cr, panel, row, x + kPadX + kAvatarSlot / 2, cy);
    DrawText(cr, row.name, x + kPadX + kAvatarSlot + kGap, cy, kMaxName, panel.text);
    if (row.muted || row.deafened) {
      DrawMark(cr, panel, row.deafened, x + pw - kPadX - kGlyph / 2, cy);
    }
    cy += kRowHeight;
  }
  if (!more.empty()) {
    DrawText(cr, more, x + kPadX + kAvatarSlot + kGap, cy, kMaxName, panel.text_muted);
  }
}

}  // namespace slimm_overlay

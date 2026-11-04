// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "screen_overlay_panel.h"

#include <glib.h>
#include <pango/pangocairo.h>

#include <algorithm>
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

// A lit dot with a soft ring while they talk, a dim dot otherwise.
void DrawPresence(cairo_t* cr, const Panel& panel, bool speaking, double cx,
                  double cy) {
  cairo_new_path(cr);
  if (speaking) {
    SetColor(cr, panel.accent, 0.4);
    cairo_set_line_width(cr, 2);
    cairo_arc(cr, cx, cy, 5.5, 0, 2 * G_PI);
    cairo_stroke(cr);
    cairo_new_path(cr);
    SetColor(cr, panel.accent);
  } else {
    SetColor(cr, panel.text_muted, 0.4);
  }
  cairo_arc(cr, cx, cy, 3.5, 0, 2 * G_PI);
  cairo_fill(cr);
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

  RoundedRect(cr, x + 0.5, y + 0.5, pw - 1, ph - 1, kRadius);
  SetColor(cr, panel.surface);
  cairo_fill_preserve(cr);
  SetColor(cr, panel.border);
  cairo_set_line_width(cr, 1);
  cairo_stroke(cr);

  double cy = y + kPadY + kRowHeight / 2;
  for (const PanelRow& row : panel.rows) {
    DrawPresence(cr, panel, row.speaking, x + kPadX + kDotBox / 2, cy);
    DrawText(cr, row.name, x + kPadX + kDotBox + kGap, cy, kMaxName, panel.text);
    if (row.muted || row.deafened) {
      DrawMark(cr, panel, row.deafened, x + pw - kPadX - kGlyph / 2, cy);
    }
    cy += kRowHeight;
  }
  if (!more.empty()) {
    DrawText(cr, more, x + kPadX + kDotBox + kGap, cy, kMaxName, panel.text_muted);
  }
}

}  // namespace slimm_overlay

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "screen_overlay.h"

#include <dlfcn.h>
#include <gtk/gtk.h>
#include <pango/pangocairo.h>

#include <cmath>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

namespace slimm_overlay {
namespace {

// gtk-layer-shell is optional at run time: it is what lets a Wayland client sit above other windows.
struct LayerShell {
  gboolean (*is_supported)() = nullptr;
  void (*init_for_window)(GtkWindow*) = nullptr;
  void (*set_layer)(GtkWindow*, int) = nullptr;
  void (*set_anchor)(GtkWindow*, int, gboolean) = nullptr;
  void (*set_exclusive_zone)(GtkWindow*, int) = nullptr;
  void (*set_keyboard_mode)(GtkWindow*, int) = nullptr;
  void (*set_monitor)(GtkWindow*, GdkMonitor*) = nullptr;
  void (*set_namespace)(GtkWindow*, const char*) = nullptr;
  bool loaded = false;
  bool tried = false;
};

constexpr int kLayerOverlay = 3;
constexpr int kEdgeLeft = 0;
constexpr int kEdgeRight = 1;
constexpr int kEdgeTop = 2;
constexpr int kEdgeBottom = 3;
constexpr int kKeyboardNone = 0;

LayerShell g_layer;
GtkWidget* g_window = nullptr;
std::vector<Shape> g_shapes;

template <typename T>
bool Bind(void* lib, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(lib, name));
  return *out != nullptr;
}

LayerShell& Layer() {
  if (g_layer.tried) return g_layer;
  g_layer.tried = true;
  void* lib = dlopen("libgtk-layer-shell.so.0", RTLD_LAZY | RTLD_GLOBAL);
  if (lib == nullptr) return g_layer;
  g_layer.loaded =
      Bind(lib, "gtk_layer_is_supported", &g_layer.is_supported) &&
      Bind(lib, "gtk_layer_init_for_window", &g_layer.init_for_window) &&
      Bind(lib, "gtk_layer_set_layer", &g_layer.set_layer) &&
      Bind(lib, "gtk_layer_set_anchor", &g_layer.set_anchor) &&
      Bind(lib, "gtk_layer_set_exclusive_zone", &g_layer.set_exclusive_zone) &&
      Bind(lib, "gtk_layer_set_keyboard_mode", &g_layer.set_keyboard_mode) &&
      Bind(lib, "gtk_layer_set_monitor", &g_layer.set_monitor) &&
      Bind(lib, "gtk_layer_set_namespace", &g_layer.set_namespace);
  return g_layer;
}

bool OnWayland() {
#ifdef GDK_WINDOWING_WAYLAND
  return GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default());
#else
  return false;
#endif
}

// Wayland needs layer-shell; X11 needs a compositor, or a transparent window paints black.
bool HostsOverlay() {
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) return false;
  if (OnWayland()) {
    LayerShell& layer = Layer();
    return layer.loaded && layer.is_supported();
  }
  GdkScreen* screen = gdk_display_get_default_screen(display);
  return gdk_screen_is_composited(screen) &&
         gdk_screen_get_rgba_visual(screen) != nullptr;
}

void SetColor(cairo_t* cr, uint32_t argb, double alpha) {
  cairo_set_source_rgba(cr, ((argb >> 16) & 0xFF) / 255.0,
                        ((argb >> 8) & 0xFF) / 255.0, (argb & 0xFF) / 255.0,
                        alpha * (((argb >> 24) & 0xFF) / 255.0));
}

void DrawStroke(cairo_t* cr, const Shape& s, double w, double h) {
  if (s.points.size() < 4) return;
  cairo_set_line_width(cr, s.width);
  cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
  cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
  SetColor(cr, s.argb, s.alpha);
  cairo_move_to(cr, s.points[0] * w, s.points[1] * h);
  for (size_t i = 2; i + 1 < s.points.size(); i += 2) {
    cairo_line_to(cr, s.points[i] * w, s.points[i + 1] * h);
  }
  cairo_stroke(cr);
}

void DrawEllipse(cairo_t* cr, const Shape& s, double w, double h) {
  if (s.points.size() != 4) return;
  double x0 = std::fmin(s.points[0], s.points[2]) * w;
  double x1 = std::fmax(s.points[0], s.points[2]) * w;
  double y0 = std::fmin(s.points[1], s.points[3]) * h;
  double y1 = std::fmax(s.points[1], s.points[3]) * h;
  if (x1 - x0 < 1 || y1 - y0 < 1) return;
  cairo_save(cr);
  cairo_translate(cr, (x0 + x1) / 2, (y0 + y1) / 2);
  cairo_scale(cr, (x1 - x0) / 2, (y1 - y0) / 2);
  cairo_new_sub_path(cr);
  cairo_arc(cr, 0, 0, 1, 0, 2 * G_PI);
  cairo_restore(cr);
  cairo_set_line_width(cr, s.width);
  SetColor(cr, s.argb, s.alpha);
  cairo_stroke(cr);
}

constexpr double kNoteRadius = 6;

void RoundedRect(cairo_t* cr, double x, double y, double w, double h, double r) {
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
  cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
  cairo_close_path(cr);
}

void DrawNote(cairo_t* cr, const Shape& s, double w, double h) {
  if (s.points.size() != 2 || s.text.empty()) return;
  constexpr double kPad = 8;
  PangoLayout* layout = pango_cairo_create_layout(cr);
  PangoFontDescription* font = pango_font_description_from_string("Sans 13");
  pango_layout_set_font_description(layout, font);
  pango_layout_set_width(layout, 260 * PANGO_SCALE);
  pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR);
  pango_layout_set_text(layout, s.text.c_str(), -1);
  int tw = 0, th = 0;
  pango_layout_get_pixel_size(layout, &tw, &th);
  double x = std::fmin(s.points[0] * w, w - tw - 2 * kPad);
  double y = std::fmin(s.points[1] * h, h - th - 2 * kPad);
  x = std::fmax(x, 0);
  y = std::fmax(y, 0);
  SetColor(cr, s.argb, s.alpha);
  RoundedRect(cr, x, y, tw + 2 * kPad, th + 2 * kPad, kNoteRadius);
  cairo_fill(cr);
  cairo_set_source_rgba(cr, 0.1, 0.1, 0.1, s.alpha);
  cairo_move_to(cr, x + kPad, y + kPad);
  pango_cairo_show_layout(cr, layout);
  pango_font_description_free(font);
  g_object_unref(layout);
}

gboolean OnDraw(GtkWidget* widget, cairo_t* cr, gpointer) {
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
  double w = gtk_widget_get_allocated_width(widget);
  double h = gtk_widget_get_allocated_height(widget);
  for (const Shape& s : g_shapes) {
    switch (s.kind) {
      case Shape::Kind::kStroke: DrawStroke(cr, s, w, h); break;
      case Shape::Kind::kEllipse: DrawEllipse(cr, s, w, h); break;
      case Shape::Kind::kNote: DrawNote(cr, s, w, h); break;
    }
  }
  return TRUE;
}

// An empty input region lets every pointer and touch event fall through to what is underneath.
void MakeClickThrough(GtkWidget* window) {
  cairo_region_t* none = cairo_region_create();
  gtk_widget_input_shape_combine_region(window, none);
  cairo_region_destroy(none);
}

void OnRealize(GtkWidget* window, gpointer) { MakeClickThrough(window); }

void OnDestroyed(GtkWidget*, gpointer) { g_window = nullptr; }

GdkMonitor* MonitorAt(int index) {
  GdkDisplay* display = gdk_display_get_default();
  int n = gdk_display_get_n_monitors(display);
  if (index < 0 || index >= n) index = 0;
  return gdk_display_get_monitor(display, index);
}

void PlaceOnWayland(GtkWindow* window, GdkMonitor* monitor) {
  LayerShell& layer = Layer();
  layer.init_for_window(window);
  layer.set_namespace(window, "slimm-screen-overlay");
  layer.set_layer(window, kLayerOverlay);
  layer.set_exclusive_zone(window, -1);
  layer.set_keyboard_mode(window, kKeyboardNone);
  layer.set_monitor(window, monitor);
  for (int edge : {kEdgeLeft, kEdgeRight, kEdgeTop, kEdgeBottom}) {
    layer.set_anchor(window, edge, TRUE);
  }
}

}  // namespace

bool Supported(std::vector<Monitor>* monitors) {
  if (!HostsOverlay()) return false;
  GdkDisplay* display = gdk_display_get_default();
  int n = gdk_display_get_n_monitors(display);
  for (int i = 0; i < n; i++) {
    GdkMonitor* monitor = gdk_display_get_monitor(display, i);
    GdkRectangle geometry;
    gdk_monitor_get_geometry(monitor, &geometry);
    monitors->push_back(
        {geometry.x, geometry.y, geometry.width, geometry.height,
         static_cast<bool>(gdk_monitor_is_primary(monitor))});
  }
  return !monitors->empty();
}

bool Show(int monitor_index) {
  if (!HostsOverlay()) return false;
  if (g_window != nullptr) gtk_widget_destroy(g_window);
  GdkMonitor* monitor = MonitorAt(monitor_index);
  GdkRectangle geometry;
  gdk_monitor_get_geometry(monitor, &geometry);

  GtkWidget* window = gtk_window_new(OnWayland() ? GTK_WINDOW_TOPLEVEL
                                                 : GTK_WINDOW_POPUP);
  GdkScreen* screen = gtk_widget_get_screen(window);
  gtk_widget_set_visual(window, gdk_screen_get_rgba_visual(screen));
  gtk_widget_set_app_paintable(window, TRUE);
  gtk_window_set_decorated(GTK_WINDOW(window), FALSE);
  gtk_window_set_skip_taskbar_hint(GTK_WINDOW(window), TRUE);
  gtk_window_set_skip_pager_hint(GTK_WINDOW(window), TRUE);
  gtk_window_set_accept_focus(GTK_WINDOW(window), FALSE);
  gtk_window_set_focus_on_map(GTK_WINDOW(window), FALSE);
  gtk_window_set_keep_above(GTK_WINDOW(window), TRUE);
  gtk_window_set_title(GTK_WINDOW(window), "slim-m screen overlay");
  gtk_window_set_default_size(GTK_WINDOW(window), geometry.width,
                              geometry.height);
  g_signal_connect(window, "draw", G_CALLBACK(OnDraw), nullptr);
  g_signal_connect(window, "realize", G_CALLBACK(OnRealize), nullptr);
  g_signal_connect(window, "destroy", G_CALLBACK(OnDestroyed), nullptr);
  if (OnWayland()) {
    PlaceOnWayland(GTK_WINDOW(window), monitor);
  } else {
    gtk_window_move(GTK_WINDOW(window), geometry.x, geometry.y);
  }
  g_shapes.clear();
  g_window = window;
  gtk_widget_show_all(window);
  return true;
}

void Draw(std::vector<Shape> shapes) {
  g_shapes = std::move(shapes);
  if (g_window != nullptr) gtk_widget_queue_draw(g_window);
}

void Hide() {
  g_shapes.clear();
  if (g_window != nullptr) gtk_widget_destroy(g_window);
  g_window = nullptr;
}

}  // namespace slimm_overlay

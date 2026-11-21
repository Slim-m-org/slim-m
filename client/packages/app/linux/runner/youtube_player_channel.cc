// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_channel.h"

#include <gio/gio.h>

#include <cmath>
#include <cstring>
#include <string>

#include "flutter_view_focus.h"
#include "webkit_loader.h"
#include "youtube_player_input.h"
#include "youtube_player_navigation.h"
#include "youtube_player_policy.h"
#include "youtube_player_texture.h"

namespace {

const char* kChannelName = "top.npcserver.slimm/youtube_player";
const char* kMessageHandler = "slimm";
// The WebKitAutoplayPolicy value from the 4.1 API.
constexpr int kAutoplayAllow = 0;
// The view sits wholly left of the window: mapped, so it plays, but nothing real reaches or shows it.
constexpr int kOffWindowGap = 64;
// After GTK's own redraws, so a capture sees WebKit's newest frame.
constexpr int kCapturePriority = GDK_PRIORITY_REDRAW + 5;
// A 60 Hz display's frame, in microseconds.
constexpr gint64 kCaptureInterval = G_USEC_PER_SEC / 60;

struct Player {
  FlMethodChannel* channel = nullptr;
  FlTextureRegistrar* registrar = nullptr;
  GtkOverlay* overlay = nullptr;
  GtkWidget* view = nullptr;
  SlimmVideoTexture* texture = nullptr;
  cairo_surface_t* frame = nullptr;
  guint capture = 0;
  gint64 last_capture = 0;
  guint frames = 0;
  gint64 frames_since = 0;
  int width = 0;
  int height = 0;
  bool fullscreen = false;
};

// One player for the one window; the channel lives as long as it does.
Player g_player;

double Number(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr) return 0;
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_FLOAT: return fl_value_get_float(value);
    case FL_VALUE_TYPE_INT: return static_cast<double>(fl_value_get_int(value));
    default: return 0;
  }
}

const char* String(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

void Send(const char* text) {
  g_debug("youtube player: page says %s", text);
  if (g_player.channel == nullptr) return;
  g_autoptr(FlValue) args = fl_value_new_string(text);
  fl_method_channel_invoke_method(g_player.channel, "message", args, nullptr,
                                  nullptr, nullptr);
}

gboolean OnChildPosition(GtkOverlay* overlay, GtkWidget* widget,
                         GdkRectangle* allocation, gpointer user_data) {
  if (widget != g_player.view) return FALSE;
  allocation->width = MAX(g_player.width, 1);
  allocation->height = MAX(g_player.height, 1);
  allocation->x = -(allocation->width + kOffWindowGap);
  allocation->y = 0;
  return TRUE;
}

GtkWidget* FlutterView() {
  return gtk_bin_get_child(GTK_BIN(g_player.overlay));
}

// The frame rate a capture keeps up, for G_MESSAGES_DEBUG=all.
void CountFrame(int width, int height) {
  const gint64 now = g_get_monotonic_time();
  if (g_player.frames_since == 0) g_player.frames_since = now;
  g_player.frames++;
  if (now - g_player.frames_since < 5 * G_USEC_PER_SEC) return;
  g_debug("youtube player: %u frames in %.1f s at %dx%d", g_player.frames,
          (now - g_player.frames_since) / 1e6, width, height);
  g_player.frames = 0;
  g_player.frames_since = now;
}

gboolean Capture(gpointer user_data) {
  g_player.capture = 0;
  g_player.last_capture = g_get_monotonic_time();
  GtkWidget* view = g_player.view;
  if (view == nullptr || g_player.texture == nullptr ||
      !gtk_widget_get_realized(view)) {
    return G_SOURCE_REMOVE;
  }
  const int scale = gtk_widget_get_scale_factor(view);
  const int width = gtk_widget_get_allocated_width(view) * scale;
  const int height = gtk_widget_get_allocated_height(view) * scale;
  if (width <= 0 || height <= 0) return G_SOURCE_REMOVE;
  cairo_surface_t* frame = g_player.frame;
  if (frame == nullptr || cairo_image_surface_get_width(frame) != width ||
      cairo_image_surface_get_height(frame) != height) {
    if (frame != nullptr) cairo_surface_destroy(frame);
    frame = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    cairo_surface_set_device_scale(frame, scale, scale);
    g_player.frame = frame;
  }
  cairo_t* cr = cairo_create(frame);
  gtk_widget_draw(view, cr);
  cairo_destroy(cr);
  cairo_surface_flush(frame);
  slimm_video_texture_store(g_player.texture, frame);
  fl_texture_registrar_mark_texture_frame_available(
      g_player.registrar, FL_TEXTURE(g_player.texture));
  CountFrame(width, height);
  return G_SOURCE_REMOVE;
}

// WebKit invalidates the view far more often than it has new frames, so copies are spaced to the display's rate.
void OnInvalidate(GdkWindow* window, cairo_region_t* region) {
  if (g_player.capture != 0) return;
  const gint64 due = g_player.last_capture + kCaptureInterval;
  const gint64 now = g_get_monotonic_time();
  g_player.capture =
      now >= due
          ? g_idle_add_full(kCapturePriority, Capture, nullptr, nullptr)
          : g_timeout_add_full(kCapturePriority,
                               static_cast<guint>((due - now + 999) / 1000),
                               Capture, nullptr, nullptr);
}

void OnRealize(GtkWidget* view, gpointer user_data) {
  gdk_window_set_invalidate_handler(gtk_widget_get_window(view), OnInvalidate);
  OnInvalidate(nullptr, nullptr);
}

void OnScriptMessage(void* manager, void* result, gpointer user_data) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  void* value = api->javascript_result_get_js_value(result);
  if (value == nullptr) return;
  g_autofree char* text = api->jsc_value_to_string(value);
  if (text != nullptr) Send(text);
}

void OpenExternally(const char* uri) {
  if (uri == nullptr) return;
  // Only a secure web link goes to the browser, never plain http, a file or a custom scheme.
  if (std::strncmp(uri, "https://", 8) != 0) return;
  g_app_info_launch_default_for_uri(uri, nullptr, nullptr);
}

// WebKit fullscreens the window (FALSE lets it); Dart covers it with the texture and sizes the view to match.
gboolean OnEnterFullscreen(GtkWidget* view, gpointer user_data) {
  g_player.fullscreen = true;
  Send("{\"event\":\"fullscreen\",\"on\":true}");
  return FALSE;
}

gboolean OnLeaveFullscreen(GtkWidget* view, gpointer user_data) {
  g_player.fullscreen = false;
  Send("{\"event\":\"fullscreen\",\"on\":false}");
  return FALSE;
}

void OnWebProcessTerminated(GtkWidget* view, int reason, gpointer user_data) {
  Send("{\"event\":\"error\",\"code\":-1}");
}

void Destroy() {
  if (g_player.capture != 0) g_source_remove(g_player.capture);
  g_player.capture = 0;
  if (g_player.view != nullptr) {
    if (g_player.fullscreen) OnLeaveFullscreen(g_player.view, nullptr);
    flutter_view_focus_take_back(FlutterView(), g_player.view);
    GdkWindow* window = gtk_widget_get_window(g_player.view);
    if (window != nullptr) gdk_window_set_invalidate_handler(window, nullptr);
    gtk_widget_destroy(g_player.view);
    g_player.view = nullptr;
  }
  if (g_player.texture != nullptr) {
    fl_texture_registrar_unregister_texture(g_player.registrar,
                                            FL_TEXTURE(g_player.texture));
    g_clear_object(&g_player.texture);
  }
  if (g_player.frame != nullptr) cairo_surface_destroy(g_player.frame);
  g_player.frame = nullptr;
  slimm_youtube::ResetPointer();
}

// Builds the view and its texture, answering the texture's id or -1.
int64_t Create(const char* html) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  if (api == nullptr || html == nullptr || g_player.registrar == nullptr) {
    return -1;
  }
  Destroy();
  SlimmVideoTexture* texture = slimm_video_texture_new();
  if (!fl_texture_registrar_register_texture(g_player.registrar,
                                             FL_TEXTURE(texture))) {
    g_object_unref(texture);
    return -1;
  }
  g_player.texture = texture;
  g_autoptr(GObject) manager = G_OBJECT(api->user_content_manager_new());
  api->register_script_message_handler(manager, kMessageHandler);
  g_signal_connect(manager, "script-message-received::slimm",
                   G_CALLBACK(OnScriptMessage), nullptr);
  // The tap that asked for the video happened in Flutter, so the page has had no gesture of its own.
  g_autoptr(GObject) policies =
      api->website_policies_get_type == nullptr
          ? nullptr
          : G_OBJECT(g_object_new(api->website_policies_get_type(), "autoplay",
                                  kAutoplayAllow, nullptr));
  GtkWidget* view = GTK_WIDGET(g_object_new(api->web_view_get_type(),
                                            "is-ephemeral", TRUE,
                                            "user-content-manager", manager,
                                            "website-policies", policies,
                                            nullptr));
  g_object_set(G_OBJECT(api->web_view_get_settings(view)),
               "media-playback-requires-user-gesture", FALSE,
               "enable-fullscreen", TRUE,
               "enable-developer-extras", FALSE, nullptr);
  slimm_youtube::GuardNavigation(view, OpenExternally);
  g_signal_connect(view, "enter-fullscreen", G_CALLBACK(OnEnterFullscreen), nullptr);
  g_signal_connect(view, "leave-fullscreen", G_CALLBACK(OnLeaveFullscreen), nullptr);
  g_signal_connect(view, "web-process-terminated",
                   G_CALLBACK(OnWebProcessTerminated), nullptr);
  g_signal_connect(view, "realize", G_CALLBACK(OnRealize), nullptr);
  g_player.view = view;
  gtk_overlay_add_overlay(g_player.overlay, view);
  // WebKit grabs GTK focus on a click, which would leave every Flutter text field deaf; keys never go to the player.
  flutter_view_focus_refuse(FlutterView(), view);
  gtk_widget_show(view);
  api->web_view_load_html(view, html, slimm_youtube::kHostOrigin);
  return fl_texture_get_id(FL_TEXTURE(texture));
}

void Resize(FlValue* args) {
  g_player.width = static_cast<int>(std::ceil(Number(args, "width")));
  g_player.height = static_cast<int>(std::ceil(Number(args, "height")));
  if (g_player.view != nullptr) gtk_widget_queue_resize(g_player.view);
}

void Pointer(FlValue* args) {
  slimm_youtube::PointerKind kind;
  if (g_player.view == nullptr ||
      !slimm_youtube::ParsePointerKind(String(args, "kind"), &kind)) {
    return;
  }
  slimm_youtube::SendPointer(g_player.view, kind, Number(args, "x"),
                             Number(args, "y"),
                             static_cast<guint>(Number(args, "button")));
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  bool is_map = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP;
  g_autoptr(FlValue) result = nullptr;
  if (g_strcmp0(method, "probe") == 0) {
    result = fl_value_new_bool(slimm_webkit::Load() != nullptr);
  } else if (g_strcmp0(method, "create") == 0) {
    result = fl_value_new_int(is_map ? Create(String(args, "html")) : -1);
  } else if (g_strcmp0(method, "resize") == 0 && is_map) {
    Resize(args);
  } else if (g_strcmp0(method, "pointer") == 0 && is_map) {
    Pointer(args);
  } else if (g_strcmp0(method, "run") == 0 && is_map) {
    const char* script = String(args, "script");
    if (g_player.view != nullptr && script != nullptr) {
      slimm_webkit::Load()->web_view_evaluate_javascript(
          g_player.view, script, -1, nullptr, nullptr, nullptr, nullptr,
          nullptr);
    }
  } else if (g_strcmp0(method, "destroy") == 0) {
    Destroy();
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  fl_method_call_respond_success(call, result, nullptr);
}

}  // namespace

void youtube_player_channel_register(FlBinaryMessenger* messenger,
                                     FlTextureRegistrar* registrar,
                                     GtkOverlay* overlay) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_player.registrar = registrar;
  g_player.overlay = overlay;
  g_signal_connect(overlay, "get-child-position", G_CALLBACK(OnChildPosition),
                   nullptr);
  g_player.channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_player.channel, HandleMethodCall,
                                            nullptr, nullptr);
}

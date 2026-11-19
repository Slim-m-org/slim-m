// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_channel.h"

#include <gio/gio.h>

#include <cmath>
#include <cstring>
#include <string>

#include "webkit_loader.h"

namespace {

const char* kChannelName = "top.npcserver.slimm/youtube_player";
const char* kHostOrigin = "https://top.npcserver.slimm/";
const char* kMessageHandler = "slimm";
// WebKitPolicyDecisionType, WebKitNavigationType and WebKitAutoplayPolicy values from the 4.1 API.
constexpr int kNavigationAction = 0;
constexpr int kNewWindowAction = 1;
constexpr int kLinkClicked = 0;
constexpr int kAutoplayAllow = 0;

struct Player {
  FlMethodChannel* channel = nullptr;
  GtkOverlay* overlay = nullptr;
  GtkWidget* view = nullptr;
  GdkRectangle bounds = {0, 0, 0, 0};
  bool visible = false;
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

// The overlay asks where the view goes; answering exactly beats margins, which a natural height left over from fullscreen outgrew.
gboolean OnChildPosition(GtkOverlay* overlay, GtkWidget* widget,
                         GdkRectangle* allocation, gpointer user_data) {
  if (widget != g_player.view) return FALSE;
  if (g_player.fullscreen) {
    allocation->x = 0;
    allocation->y = 0;
    allocation->width = gtk_widget_get_allocated_width(GTK_WIDGET(overlay));
    allocation->height = gtk_widget_get_allocated_height(GTK_WIDGET(overlay));
  } else {
    *allocation = g_player.bounds;
  }
  return TRUE;
}

void ApplyGeometry() {
  GtkWidget* view = g_player.view;
  if (view == nullptr) return;
  bool show = g_player.fullscreen ||
              (g_player.visible && g_player.bounds.width > 0 &&
               g_player.bounds.height > 0);
  gtk_widget_set_visible(view, show);
  gtk_widget_queue_resize(view);
}

void OnScriptMessage(void* manager, void* result, gpointer user_data) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  void* value = api->javascript_result_get_js_value(result);
  if (value == nullptr) return;
  g_autofree char* text = api->jsc_value_to_string(value);
  if (text != nullptr) Send(text);
}

bool IsHostPage(const char* uri) {
  return uri != nullptr && std::strncmp(uri, kHostOrigin, std::strlen(kHostOrigin)) == 0;
}

void OpenExternally(const char* uri) {
  if (uri == nullptr) return;
  if (std::strncmp(uri, "https://", 8) != 0 && std::strncmp(uri, "http://", 7) != 0) {
    return;
  }
  g_app_info_launch_default_for_uri(uri, nullptr, nullptr);
}

// The player's own frames load in place; a clicked link or a new window (the YouTube logo, "watch on YouTube") opens in the browser.
gboolean OnDecidePolicy(GtkWidget* view, void* decision, int type,
                        gpointer user_data) {
  if (type != kNavigationAction && type != kNewWindowAction) return FALSE;
  const slimm_webkit::Api* api = slimm_webkit::Load();
  void* action = api->policy_decision_get_navigation_action(decision);
  const char* uri =
      api->uri_request_get_uri(api->navigation_action_get_request(action));
  bool clicked = api->navigation_action_get_navigation_type(action) == kLinkClicked;
  if (type == kNewWindowAction || (clicked && !IsHostPage(uri))) {
    OpenExternally(uri);
    api->policy_decision_ignore(decision);
    return TRUE;
  }
  api->policy_decision_use(decision);
  return TRUE;
}

// The view fills the window and WebKit fullscreens the window (FALSE lets it); Dart hides its own chrome.
gboolean OnEnterFullscreen(GtkWidget* view, gpointer user_data) {
  g_player.fullscreen = true;
  ApplyGeometry();
  Send("{\"event\":\"fullscreen\",\"on\":true}");
  return FALSE;
}

gboolean OnLeaveFullscreen(GtkWidget* view, gpointer user_data) {
  g_player.fullscreen = false;
  ApplyGeometry();
  Send("{\"event\":\"fullscreen\",\"on\":false}");
  return FALSE;
}

void OnWebProcessTerminated(GtkWidget* view, int reason, gpointer user_data) {
  Send("{\"event\":\"error\",\"code\":-1}");
}

void Destroy() {
  if (g_player.view == nullptr) return;
  if (g_player.fullscreen) OnLeaveFullscreen(g_player.view, nullptr);
  gtk_widget_destroy(g_player.view);
  g_player.view = nullptr;
  g_player.visible = false;
}

bool Create(const char* html) {
  const slimm_webkit::Api* api = slimm_webkit::Load();
  if (api == nullptr || html == nullptr) return false;
  Destroy();
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
  g_signal_connect(view, "decide-policy", G_CALLBACK(OnDecidePolicy), nullptr);
  g_signal_connect(view, "enter-fullscreen", G_CALLBACK(OnEnterFullscreen), nullptr);
  g_signal_connect(view, "leave-fullscreen", G_CALLBACK(OnLeaveFullscreen), nullptr);
  g_signal_connect(view, "web-process-terminated",
                   G_CALLBACK(OnWebProcessTerminated), nullptr);
  g_player.view = view;
  gtk_overlay_add_overlay(g_player.overlay, view);
  ApplyGeometry();
  api->web_view_load_html(view, html, kHostOrigin);
  return true;
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* call,
                      gpointer user_data) {
  const gchar* method = fl_method_call_get_name(call);
  g_debug("youtube player: %s", method);
  FlValue* args = fl_method_call_get_args(call);
  bool is_map = args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP;
  g_autoptr(FlValue) result = nullptr;
  if (g_strcmp0(method, "probe") == 0) {
    result = fl_value_new_bool(slimm_webkit::Load() != nullptr);
  } else if (g_strcmp0(method, "create") == 0) {
    result = fl_value_new_bool(is_map && Create(String(args, "html")));
  } else if (g_strcmp0(method, "setBounds") == 0 && is_map) {
    g_player.bounds = {static_cast<int>(std::lround(Number(args, "x"))),
                       static_cast<int>(std::lround(Number(args, "y"))),
                       static_cast<int>(std::lround(Number(args, "width"))),
                       static_cast<int>(std::lround(Number(args, "height")))};
    ApplyGeometry();
  } else if (g_strcmp0(method, "setVisible") == 0 && is_map) {
    FlValue* visible = fl_value_lookup_string(args, "visible");
    g_player.visible = visible != nullptr &&
                       fl_value_get_type(visible) == FL_VALUE_TYPE_BOOL &&
                       fl_value_get_bool(visible);
    ApplyGeometry();
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
                                     GtkOverlay* overlay) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_player.overlay = overlay;
  g_signal_connect(overlay, "get-child-position", G_CALLBACK(OnChildPosition),
                   nullptr);
  g_player.channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_player.channel, HandleMethodCall,
                                            nullptr, nullptr);
}

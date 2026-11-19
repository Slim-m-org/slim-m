// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "webkit_loader.h"

#include <dlfcn.h>

namespace slimm_webkit {
namespace {

// The 4.1 API is GTK3, the toolkit Flutter's embedder uses; 6.0 is GTK4.
const char* kLibrary = "libwebkit2gtk-4.1.so.0";
// webkit_web_view_evaluate_javascript arrived in 2.40.
constexpr unsigned kMinMajor = 2;
constexpr unsigned kMinMinor = 40;

Api g_api;
bool g_tried = false;
bool g_loaded = false;

template <typename T>
bool Bind(void* lib, const char* name, T* out) {
  *out = reinterpret_cast<T>(dlsym(lib, name));
  return *out != nullptr;
}

bool VersionSupported(void* lib) {
  unsigned (*major)() = nullptr;
  unsigned (*minor)() = nullptr;
  if (!Bind(lib, "webkit_get_major_version", &major) ||
      !Bind(lib, "webkit_get_minor_version", &minor)) {
    return false;
  }
  return major() > kMinMajor || (major() == kMinMajor && minor() >= kMinMinor);
}

// libsoup2 and libsoup3 abort when they meet in one process, and WebKit 4.1 brings 3.
bool Soup2Loaded() {
  void* soup2 = dlopen("libsoup-2.4.so.1", RTLD_LAZY | RTLD_NOLOAD);
  if (soup2 == nullptr) return false;
  dlclose(soup2);
  return true;
}

bool BindAll(void* lib) {
  return Bind(lib, "webkit_web_view_get_type", &g_api.web_view_get_type) &&
         Bind(lib, "webkit_user_content_manager_new",
              &g_api.user_content_manager_new) &&
         Bind(lib, "webkit_user_content_manager_register_script_message_handler",
              &g_api.register_script_message_handler) &&
         Bind(lib, "webkit_web_view_get_settings",
              &g_api.web_view_get_settings) &&
         Bind(lib, "webkit_web_view_load_html", &g_api.web_view_load_html) &&
         Bind(lib, "webkit_web_view_evaluate_javascript",
              &g_api.web_view_evaluate_javascript) &&
         Bind(lib, "webkit_navigation_policy_decision_get_navigation_action",
              &g_api.policy_decision_get_navigation_action) &&
         Bind(lib, "webkit_navigation_action_get_request",
              &g_api.navigation_action_get_request) &&
         Bind(lib, "webkit_navigation_action_get_navigation_type",
              &g_api.navigation_action_get_navigation_type) &&
         Bind(lib, "webkit_uri_request_get_uri", &g_api.uri_request_get_uri) &&
         Bind(lib, "webkit_policy_decision_use", &g_api.policy_decision_use) &&
         Bind(lib, "webkit_policy_decision_ignore",
              &g_api.policy_decision_ignore) &&
         Bind(lib, "webkit_javascript_result_get_js_value",
              &g_api.javascript_result_get_js_value) &&
         Bind(lib, "jsc_value_to_string", &g_api.jsc_value_to_string);
}

}  // namespace

const Api* Load() {
  if (g_tried) return g_loaded ? &g_api : nullptr;
  g_tried = true;
  if (Soup2Loaded()) {
    g_warning("youtube player: libsoup2 is loaded, WebKitGTK cannot join it");
    return nullptr;
  }
  void* lib = dlopen(kLibrary, RTLD_LAZY | RTLD_LOCAL);
  if (lib == nullptr) return nullptr;
  if (!VersionSupported(lib)) {
    g_warning("youtube player: %s is older than %u.%u", kLibrary, kMinMajor,
              kMinMinor);
    return nullptr;
  }
  Bind(lib, "webkit_website_policies_get_type", &g_api.website_policies_get_type);
  if (!BindAll(lib)) {
    g_warning("youtube player: %s lacks a call the player needs", kLibrary);
    return nullptr;
  }
  g_loaded = true;
  return &g_api;
}

}  // namespace slimm_webkit

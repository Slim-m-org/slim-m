// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_WEBKIT_LOADER_H_
#define RUNNER_WEBKIT_LOADER_H_

#include <gtk/gtk.h>

/// WebKitGTK 4.1 loaded at run time with dlopen, never linked: Flutter's Linux
/// embedder loads every library at startup, so a NEEDED entry on it would stop
/// the app from starting on a machine (or flatpak runtime) without WebKit. The
/// types stay opaque; only the calls the YouTube panel makes are bound.
namespace slimm_webkit {

struct Api {
  GType (*web_view_get_type)() = nullptr;
  void* (*user_content_manager_new)() = nullptr;
  gboolean (*register_script_message_handler)(void* manager,
                                              const char* name) = nullptr;
  void* (*web_view_get_settings)(void* view) = nullptr;
  void (*web_view_load_html)(void* view, const char* html,
                             const char* base_uri) = nullptr;
  void (*web_view_evaluate_javascript)(void* view, const char* script,
                                       gssize length, const char* world_name,
                                       const char* source_uri,
                                       GCancellable* cancellable,
                                       GAsyncReadyCallback callback,
                                       gpointer user_data) = nullptr;
  void* (*policy_decision_get_navigation_action)(void* decision) = nullptr;
  void* (*navigation_action_get_request)(void* action) = nullptr;
  int (*navigation_action_get_navigation_type)(void* action) = nullptr;
  const char* (*uri_request_get_uri)(void* request) = nullptr;
  void (*policy_decision_use)(void* decision) = nullptr;
  void (*policy_decision_ignore)(void* decision) = nullptr;
  void* (*javascript_result_get_js_value)(void* result) = nullptr;
  char* (*jsc_value_to_string)(void* value) = nullptr;
  /// Optional: null leaves WebKit's default autoplay policy.
  GType (*website_policies_get_type)() = nullptr;
};

/// The bound API, or null when WebKitGTK 4.1 (2.40 or newer) is not installed
/// or cannot share this process. Loads once; later calls return the same answer.
const Api* Load();

}  // namespace slimm_webkit

#endif  // RUNNER_WEBKIT_LOADER_H_

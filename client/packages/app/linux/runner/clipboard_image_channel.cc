// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "clipboard_image_channel.h"

#include "clipboard_image_limits.h"

#include <gtk/gtk.h>

#include <cstdint>
#include <cstring>

namespace {

// Shared with the Dart stub and the mobile implementations.
const char* kChannelName = "top.npcserver.slimm/clipboard_image";

GtkClipboard* DefaultClipboard() {
  return gtk_clipboard_get_default(gdk_display_get_default());
}

constexpr guint kTargetsTimeoutMs = 1500;
constexpr char kTooLargeMessage[] = "That image is too large to copy.";

void RespondWriteFailed(FlMethodCall* call, const char* message) {
  fl_method_call_respond_error(call, "write_failed", message, nullptr, nullptr);
}

// One answer for a call that two callbacks race to give.
struct TargetsQuery {
  FlMethodCall* call;
  bool answered;
  int refs;
};

void ReleaseTargetsQuery(TargetsQuery* query) {
  if (--query->refs > 0) return;
  g_object_unref(query->call);
  delete query;
}

void AnswerHasImage(TargetsQuery* query, bool has_image) {
  if (!query->answered) {
    query->answered = true;
    g_autoptr(FlValue) result = fl_value_new_bool(has_image);
    fl_method_call_respond_success(query->call, result, nullptr);
  }
  ReleaseTargetsQuery(query);
}

void OnTargets(GtkClipboard* clipboard, GdkAtom* targets, gint n_targets,
               gpointer user_data) {
  AnswerHasImage(static_cast<TargetsQuery*>(user_data),
                 targets != nullptr &&
                     gtk_targets_include_image(targets, n_targets, FALSE));
}

gboolean OnTargetsTimeout(gpointer user_data) {
  AnswerHasImage(static_cast<TargetsQuery*>(user_data), false);
  return G_SOURCE_REMOVE;
}

/// Asks the clipboard owner for its targets without blocking the UI thread;
/// an owner that never answers is treated as holding no image.
void HandleHasImage(FlMethodCall* call) {
  auto* query = new TargetsQuery{FL_METHOD_CALL(g_object_ref(call)), false, 2};
  g_timeout_add(kTargetsTimeoutMs, OnTargetsTimeout, query);
  gtk_clipboard_request_targets(DefaultClipboard(), OnTargets, query);
}

/// Runs on a worker thread: encoded as PNG so the bytes match what the
/// composer's own staging path already expects from a picked file or a web paste.
void EncodePngInThread(GTask* task, gpointer source, gpointer task_data,
                       GCancellable* cancellable) {
  auto* pixbuf = GDK_PIXBUF(task_data);
  gchar* buffer = nullptr;
  gsize buffer_size = 0;
  GError* error = nullptr;
  if (!gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &buffer_size, "png", &error,
                                 nullptr)) {
    g_task_return_error(task, error);
    return;
  }
  g_task_return_pointer(task, g_bytes_new_take(buffer, buffer_size),
                        reinterpret_cast<GDestroyNotify>(g_bytes_unref));
}

void OnPngEncoded(GObject* source, GAsyncResult* result, gpointer user_data) {
  auto* call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GBytes) png = static_cast<GBytes*>(
      g_task_propagate_pointer(G_TASK(result), &error));
  if (png == nullptr) {
    fl_method_call_respond_error(
        call, "read_failed", "The clipboard image could not be read.", nullptr,
        nullptr);
  } else {
    gsize size = 0;
    const auto* data = static_cast<const uint8_t*>(g_bytes_get_data(png, &size));
    g_autoptr(FlValue) value = fl_value_new_uint8_list(data, size);
    fl_method_call_respond_success(call, value, nullptr);
  }
  g_object_unref(call);
}

void OnImageReceived(GtkClipboard* clipboard, GdkPixbuf* pixbuf,
                     gpointer user_data) {
  auto* call = FL_METHOD_CALL(user_data);
  if (pixbuf == nullptr) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    g_object_unref(call);
    return;
  }
  if (slimm_clipboard::ImageTooLarge(gdk_pixbuf_get_width(pixbuf),
                                     gdk_pixbuf_get_height(pixbuf))) {
    fl_method_call_respond_error(call, "read_failed",
                                 "That image is too large to paste.", nullptr,
                                 nullptr);
    g_object_unref(call);
    return;
  }
  g_autoptr(GTask) task = g_task_new(nullptr, nullptr, OnPngEncoded, call);
  g_task_set_task_data(task, g_object_ref(pixbuf), g_object_unref);
  g_task_run_in_thread(task, EncodePngInThread);
}

/// An owner that offers PNG hands those bytes over untouched, which skips the
/// decode and the re-encode; any other image format goes through a pixbuf.
void OnPngContents(GtkClipboard* clipboard, GtkSelectionData* selection,
                   gpointer user_data) {
  auto* call = FL_METHOD_CALL(user_data);
  const gint length = gtk_selection_data_get_length(selection);
  const guchar* data = gtk_selection_data_get_data(selection);
  int width = 0;
  int height = 0;
  if (length <= 0 ||
      !slimm_clipboard::PngDimensions(data, length, &width, &height)) {
    gtk_clipboard_request_image(clipboard, OnImageReceived, call);
    return;
  }
  if (slimm_clipboard::ImageTooLarge(width, height)) {
    fl_method_call_respond_error(
        call, "read_failed", "That image is too large to paste.", nullptr,
        nullptr);
  } else {
    g_autoptr(FlValue) value = fl_value_new_uint8_list(data, length);
    fl_method_call_respond_success(call, value, nullptr);
  }
  g_object_unref(call);
}

void HandleReadImage(FlMethodCall* call) {
  gtk_clipboard_request_contents(
      DefaultClipboard(), gdk_atom_intern_static_string("image/png"),
      OnPngContents, g_object_ref(call));
}

struct DecodeLimit {
  bool exceeded;
};

void OnSizePrepared(GdkPixbufLoader* loader, gint width, gint height,
                    gpointer user_data) {
  if (!slimm_clipboard::WriteImageTooLarge(width, height)) return;
  static_cast<DecodeLimit*>(user_data)->exceeded = true;
  gdk_pixbuf_loader_set_size(loader, 1, 1);
}

/// Runs on a worker thread. A canvas past the cap is shrunk to one pixel as soon
/// as its size is known, so it is never decoded at full size.
void DecodePngInThread(GTask* task, gpointer source, gpointer task_data,
                       GCancellable* cancellable) {
  auto* png = static_cast<GBytes*>(task_data);
  DecodeLimit limit = {false};
  GdkPixbufLoader* loader = gdk_pixbuf_loader_new();
  g_signal_connect(loader, "size-prepared", G_CALLBACK(OnSizePrepared), &limit);
  gsize size = 0;
  const auto* data = static_cast<const guchar*>(g_bytes_get_data(png, &size));
  GError* error = nullptr;
  gboolean decoded = gdk_pixbuf_loader_write(loader, data, size, &error) &&
                     gdk_pixbuf_loader_close(loader, &error);
  GdkPixbuf* pixbuf = decoded && !limit.exceeded
                          ? gdk_pixbuf_loader_get_pixbuf(loader)
                          : nullptr;
  if (pixbuf != nullptr) g_object_ref(pixbuf);
  g_object_unref(loader);
  if (pixbuf == nullptr) {
    g_clear_error(&error);
    g_task_return_new_error(task, G_IO_ERROR,
                            limit.exceeded ? G_IO_ERROR_MESSAGE_TOO_LARGE
                                           : G_IO_ERROR_FAILED,
                            "decode failed");
    return;
  }
  g_task_return_pointer(task, pixbuf, g_object_unref);
}

void OnPngDecoded(GObject* source, GAsyncResult* result, gpointer user_data) {
  auto* call = FL_METHOD_CALL(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GdkPixbuf) pixbuf = static_cast<GdkPixbuf*>(
      g_task_propagate_pointer(G_TASK(result), &error));
  if (pixbuf == nullptr) {
    const bool too_large = g_error_matches(error, G_IO_ERROR,
                                           G_IO_ERROR_MESSAGE_TOO_LARGE);
    RespondWriteFailed(call, too_large ? kTooLargeMessage
                                       : "The image could not be copied.");
  } else {
    gtk_clipboard_set_image(DefaultClipboard(), pixbuf);
    gtk_clipboard_set_can_store(DefaultClipboard(), nullptr, 0);
    fl_method_call_respond_success(call, nullptr, nullptr);
  }
  g_object_unref(call);
}

// The bytes arrive as PNG (the Dart side converts); GTK offers the pixbuf to
// other apps in whatever image formats they ask for.
void HandleWriteImage(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
    RespondWriteFailed(call, "The image could not be copied.");
    return;
  }
  int width = 0;
  int height = 0;
  if (slimm_clipboard::PngDimensions(fl_value_get_uint8_list(args),
                                     fl_value_get_length(args), &width,
                                     &height) &&
      slimm_clipboard::WriteImageTooLarge(width, height)) {
    RespondWriteFailed(call, kTooLargeMessage);
    return;
  }
  g_autoptr(GTask) task =
      g_task_new(nullptr, nullptr, OnPngDecoded, g_object_ref(call));
  g_task_set_task_data(
      task,
      g_bytes_new(fl_value_get_uint8_list(args), fl_value_get_length(args)),
      reinterpret_cast<GDestroyNotify>(g_bytes_unref));
  g_task_run_in_thread(task, DecodePngInThread);
}

enum FileTarget { kUriList, kGnomeCopiedFiles, kPlainText };

void ProvideCopiedFile(GtkClipboard* clipboard, GtkSelectionData* selection,
                       guint info, gpointer user_data) {
  const gchar* uri = static_cast<const gchar*>(user_data);
  if (info == kGnomeCopiedFiles) {
    g_autoptr(GString) payload = g_string_new("copy\n");
    g_string_append(payload, uri);
    gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
                           8, reinterpret_cast<const guchar*>(payload->str),
                           payload->len);
  } else if (info == kUriList) {
    g_autoptr(GString) payload = g_string_new(uri);
    g_string_append(payload, "\r\n");
    gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
                           8, reinterpret_cast<const guchar*>(payload->str),
                           payload->len);
  } else {
    gtk_selection_data_set_text(selection, uri, -1);
  }
}

// The clipboard owns the URI until another copy replaces it.
void ReleaseCopiedFile(GtkClipboard* clipboard, gpointer user_data) {
  g_free(user_data);
}

// Offers a file already on disk the way a file manager's Copy does, so a paste
// elsewhere receives the file itself rather than its bytes.
void HandleWriteFile(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_STRING) {
    fl_method_call_respond_error(call, "write_failed",
                                 "The file could not be copied.", nullptr,
                                 nullptr);
    return;
  }
  g_autoptr(GError) error = nullptr;
  gchar* uri = g_filename_to_uri(fl_value_get_string(args), nullptr, &error);
  if (uri == nullptr) {
    fl_method_call_respond_error(call, "write_failed",
                                 "The file could not be copied.", nullptr,
                                 nullptr);
    return;
  }
  static const GtkTargetEntry targets[] = {
      {const_cast<gchar*>("x-special/gnome-copied-files"), 0, kGnomeCopiedFiles},
      {const_cast<gchar*>("text/uri-list"), 0, kUriList},
      {const_cast<gchar*>("UTF8_STRING"), 0, kPlainText},
      {const_cast<gchar*>("text/plain;charset=utf-8"), 0, kPlainText},
  };
  gboolean set = gtk_clipboard_set_with_data(
      DefaultClipboard(), targets, G_N_ELEMENTS(targets), ProvideCopiedFile,
      ReleaseCopiedFile, uri);
  if (!set) {
    g_free(uri);
    fl_method_call_respond_error(call, "write_failed",
                                 "The clipboard refused the file.", nullptr,
                                 nullptr);
    return;
  }
  gtk_clipboard_set_can_store(DefaultClipboard(), nullptr, 0);
  fl_method_call_respond_success(call, nullptr, nullptr);
}

void HandleMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                      gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "hasImage") == 0) {
    HandleHasImage(method_call);
  } else if (g_strcmp0(method, "readImage") == 0) {
    HandleReadImage(method_call);
  } else if (g_strcmp0(method, "writeImage") == 0) {
    HandleWriteImage(method_call);
  } else if (g_strcmp0(method, "writeFile") == 0) {
    HandleWriteFile(method_call);
  } else {
    fl_method_call_respond_not_implemented(method_call, nullptr);
  }
}

}  // namespace

void clipboard_image_channel_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Deliberately never released: the channel must outlive every call it
  // answers, which in practice means the life of the application.
  FlMethodChannel* channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, HandleMethodCall,
                                            nullptr, nullptr);
}

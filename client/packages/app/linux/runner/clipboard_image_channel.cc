// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "clipboard_image_channel.h"

#include <gtk/gtk.h>

#include <cstring>

namespace {

// Shared with the Dart stub and the mobile implementations.
const char* kChannelName = "top.npcserver.slimm/clipboard_image";

GtkClipboard* DefaultClipboard() {
  return gtk_clipboard_get_default(gdk_display_get_default());
}

// Metadata only, the same exemption UIPasteboard.hasImages and Android's
// ClipboardDescription.hasMimeType rely on: this never blocks on the
// clipboard owner and never surfaces a permission prompt.
void HandleHasImage(FlMethodCall* call) {
  gboolean has_image = gtk_clipboard_wait_is_image_available(DefaultClipboard());
  g_autoptr(FlValue) result = fl_value_new_bool(has_image);
  fl_method_call_respond_success(call, result, nullptr);
}

// Encoded as PNG so the bytes match what the composer's own staging path
// already expects from a picked file or a web paste.
void HandleReadImage(FlMethodCall* call) {
  GdkPixbuf* pixbuf = gtk_clipboard_wait_for_image(DefaultClipboard());
  if (pixbuf == nullptr) {
    fl_method_call_respond_success(call, fl_value_new_null(), nullptr);
    return;
  }

  gchar* buffer = nullptr;
  gsize buffer_size = 0;
  g_autoptr(GError) error = nullptr;
  gboolean saved = gdk_pixbuf_save_to_buffer(
      pixbuf, &buffer, &buffer_size, "png", &error, nullptr);
  g_object_unref(pixbuf);

  if (!saved) {
    fl_method_call_respond_error(
        call, "read_failed", "The clipboard image could not be read.",
        nullptr, nullptr);
    return;
  }

  g_autoptr(FlValue) result = fl_value_new_uint8_list(
      reinterpret_cast<const uint8_t*>(buffer), buffer_size);
  g_free(buffer);
  fl_method_call_respond_success(call, result, nullptr);
}

// The bytes arrive as PNG (the Dart side converts); GTK offers the pixbuf to
// other apps in whatever image formats they ask for.
void HandleWriteImage(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_UINT8_LIST) {
    fl_method_call_respond_error(call, "write_failed",
                                 "The image could not be copied.", nullptr,
                                 nullptr);
    return;
  }

  GdkPixbufLoader* loader = gdk_pixbuf_loader_new();
  g_autoptr(GError) error = nullptr;
  gboolean decoded =
      gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(args),
                              fl_value_get_length(args), &error) &&
      gdk_pixbuf_loader_close(loader, &error);
  GdkPixbuf* pixbuf = decoded ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
  if (pixbuf == nullptr) {
    g_object_unref(loader);
    fl_method_call_respond_error(call, "write_failed",
                                 "The image could not be copied.", nullptr,
                                 nullptr);
    return;
  }

  gtk_clipboard_set_image(DefaultClipboard(), pixbuf);
  g_object_unref(loader);
  fl_method_call_respond_success(call, nullptr, nullptr);
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

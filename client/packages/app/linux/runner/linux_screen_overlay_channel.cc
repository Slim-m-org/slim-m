// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "linux_screen_overlay_channel.h"

#include <string>
#include <vector>

#include "screen_overlay.h"

namespace {

const char* kChannelName = "slimm/screen_overlay";
// Never released: the channel lives as long as the one window.
FlMethodChannel* g_channel = nullptr;

double Number(FlValue* value, double fallback = 0) {
  if (value == nullptr) return fallback;
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_FLOAT: return fl_value_get_float(value);
    case FL_VALUE_TYPE_INT: return static_cast<double>(fl_value_get_int(value));
    default: return fallback;
  }
}

std::vector<double> Numbers(FlValue* list) {
  std::vector<double> out;
  if (list == nullptr || fl_value_get_type(list) != FL_VALUE_TYPE_LIST) {
    return out;
  }
  for (size_t i = 0; i < fl_value_get_length(list); i++) {
    out.push_back(Number(fl_value_get_list_value(list, i)));
  }
  return out;
}

FlValue* Field(FlValue* map, const char* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(map, key);
}

slimm_overlay::Shape ShapeFrom(FlValue* map) {
  slimm_overlay::Shape shape;
  FlValue* kind = Field(map, "t");
  std::string name = kind != nullptr && fl_value_get_type(kind) == FL_VALUE_TYPE_STRING
                         ? fl_value_get_string(kind)
                         : "";
  shape.argb = static_cast<uint32_t>(
      static_cast<int64_t>(Number(Field(map, "color"), 0xFFFF0000)));
  shape.alpha = Number(Field(map, "alpha"), 1);
  shape.width = Number(Field(map, "width"), 4);
  if (name == "ellipse") {
    shape.kind = slimm_overlay::Shape::Kind::kEllipse;
    shape.points = Numbers(Field(map, "rect"));
  } else if (name == "note") {
    shape.kind = slimm_overlay::Shape::Kind::kNote;
    shape.points = {Number(Field(map, "x")), Number(Field(map, "y"))};
    FlValue* text = Field(map, "text");
    if (text != nullptr && fl_value_get_type(text) == FL_VALUE_TYPE_STRING) {
      shape.text = fl_value_get_string(text);
    }
  } else {
    shape.kind = slimm_overlay::Shape::Kind::kStroke;
    shape.points = Numbers(Field(map, "points"));
  }
  return shape;
}

FlValue* SupportReply() {
  std::vector<slimm_overlay::Monitor> monitors;
  g_autoptr(FlValue) reply = fl_value_new_map();
  bool supported = slimm_overlay::Supported(&monitors);
  fl_value_set_string_take(reply, "supported", fl_value_new_bool(supported));
  FlValue* list = fl_value_new_list();
  for (const auto& m : monitors) {
    FlValue* entry = fl_value_new_map();
    fl_value_set_string_take(entry, "x", fl_value_new_int(m.x));
    fl_value_set_string_take(entry, "y", fl_value_new_int(m.y));
    fl_value_set_string_take(entry, "width", fl_value_new_int(m.width));
    fl_value_set_string_take(entry, "height", fl_value_new_int(m.height));
    fl_value_set_string_take(entry, "primary", fl_value_new_bool(m.primary));
    fl_value_append_take(list, entry);
  }
  fl_value_set_string_take(reply, "monitors", list);
  return fl_value_ref(reply);
}

void OnMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "support") == 0) {
    g_autoptr(FlValue) reply = SupportReply();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(reply));
  } else if (g_strcmp0(method, "show") == 0) {
    bool shown = slimm_overlay::Show(static_cast<int>(Number(Field(args, "monitor"))));
    g_autoptr(FlValue) reply = fl_value_new_bool(shown);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(reply));
  } else if (g_strcmp0(method, "draw") == 0) {
    std::vector<slimm_overlay::Shape> shapes;
    FlValue* list = Field(args, "shapes");
    if (list != nullptr && fl_value_get_type(list) == FL_VALUE_TYPE_LIST) {
      for (size_t i = 0; i < fl_value_get_length(list); i++) {
        shapes.push_back(ShapeFrom(fl_value_get_list_value(list, i)));
      }
    }
    slimm_overlay::Draw(std::move(shapes));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (g_strcmp0(method, "hide") == 0) {
    slimm_overlay::Hide();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void linux_screen_overlay_channel_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, OnMethodCall, nullptr,
                                            nullptr);
}

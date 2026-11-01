#include "screen_overlay_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

#include "screen_overlay_win.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

double NumberOf(const EncodableValue* value, double fallback) {
  if (value == nullptr) return fallback;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* i = std::get_if<int32_t>(value)) return static_cast<double>(*i);
  if (const auto* l = std::get_if<int64_t>(value)) return static_cast<double>(*l);
  return fallback;
}

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  auto found = map.find(EncodableValue(key));
  return found == map.end() ? nullptr : &found->second;
}

std::vector<double> NumbersOf(const EncodableValue* value) {
  std::vector<double> out;
  if (value == nullptr) return out;
  const auto* list = std::get_if<EncodableList>(value);
  if (list == nullptr) return out;
  for (const auto& item : *list) out.push_back(NumberOf(&item, 0));
  return out;
}

std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      &wide[0], length);
  return wide;
}

slimm_overlay::Shape ShapeOf(const EncodableMap& map) {
  slimm_overlay::Shape shape;
  std::string kind;
  if (const auto* t = Field(map, "t")) {
    if (const auto* s = std::get_if<std::string>(t)) kind = *s;
  }
  shape.argb = static_cast<uint32_t>(
      static_cast<int64_t>(NumberOf(Field(map, "color"), 4294901760.0)));
  shape.alpha = NumberOf(Field(map, "alpha"), 1);
  shape.width = NumberOf(Field(map, "width"), 4);
  if (kind == "ellipse") {
    shape.kind = slimm_overlay::Shape::Kind::kEllipse;
    shape.points = NumbersOf(Field(map, "rect"));
  } else if (kind == "note") {
    shape.kind = slimm_overlay::Shape::Kind::kNote;
    shape.points = {NumberOf(Field(map, "x"), 0), NumberOf(Field(map, "y"), 0)};
    if (const auto* text = Field(map, "text")) {
      if (const auto* s = std::get_if<std::string>(text)) {
        shape.text = WideFromUtf8(*s);
      }
    }
  } else {
    shape.kind = slimm_overlay::Shape::Kind::kStroke;
    shape.points = NumbersOf(Field(map, "points"));
  }
  return shape;
}

EncodableValue SupportReply() {
  std::vector<slimm_overlay::Monitor> monitors;
  bool supported = slimm_overlay::Supported(&monitors);
  EncodableList list;
  for (const auto& m : monitors) {
    EncodableMap entry;
    entry[EncodableValue("x")] = EncodableValue(m.x);
    entry[EncodableValue("y")] = EncodableValue(m.y);
    entry[EncodableValue("width")] = EncodableValue(m.width);
    entry[EncodableValue("height")] = EncodableValue(m.height);
    entry[EncodableValue("primary")] = EncodableValue(m.primary);
    list.push_back(EncodableValue(entry));
  }
  EncodableMap reply;
  reply[EncodableValue("supported")] = EncodableValue(supported);
  reply[EncodableValue("monitors")] = EncodableValue(list);
  return EncodableValue(reply);
}

}  // namespace

void RegisterScreenOverlayChannel(flutter::BinaryMessenger* messenger) {
  static std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "slimm/screen_overlay",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        const auto* args = call.arguments() == nullptr
                               ? nullptr
                               : std::get_if<EncodableMap>(call.arguments());
        if (method == "support") {
          result->Success(SupportReply());
        } else if (method == "show") {
          int monitor = 0;
          if (args != nullptr) {
            monitor = static_cast<int>(NumberOf(Field(*args, "monitor"), 0));
          }
          result->Success(EncodableValue(slimm_overlay::Show(monitor)));
        } else if (method == "draw") {
          std::vector<slimm_overlay::Shape> shapes;
          const EncodableValue* raw = args == nullptr ? nullptr : Field(*args, "shapes");
          if (raw != nullptr) {
            if (const auto* list = std::get_if<EncodableList>(raw)) {
              for (const auto& item : *list) {
                if (const auto* map = std::get_if<EncodableMap>(&item)) {
                  shapes.push_back(ShapeOf(*map));
                }
              }
            }
          }
          slimm_overlay::Draw(std::move(shapes));
          result->Success();
        } else if (method == "hide") {
          slimm_overlay::Hide();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

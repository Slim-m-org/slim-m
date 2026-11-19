// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <variant>

#include "youtube_player_geometry.h"
#include "youtube_player_win.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
HWND g_view = nullptr;

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

double Number(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Field(map, key);
  if (value == nullptr) return 0;
  if (const double* d = std::get_if<double>(value)) return *d;
  if (const int32_t* i = std::get_if<int32_t>(value)) return *i;
  if (const int64_t* l = std::get_if<int64_t>(value)) {
    return static_cast<double>(*l);
  }
  return 0;
}

std::string Text(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Field(map, key);
  if (value == nullptr) return std::string();
  const std::string* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

void SendMessageToDart(const std::string& json) {
  if (g_channel) {
    g_channel->InvokeMethod("message", std::make_unique<EncodableValue>(json));
  }
}

RECT Physical(const EncodableMap& args) {
  double scale = GetDpiForWindow(g_view) / 96.0;
  slimm::PixelRect rect =
      slimm::ToPhysical(Number(args, "x"), Number(args, "y"),
                        Number(args, "width"), Number(args, "height"), scale);
  return RECT{rect.left, rect.top, rect.right, rect.bottom};
}

void Handle(const flutter::MethodCall<EncodableValue>& call,
            std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableMap* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "probe") {
    result->Success(EncodableValue(slimm_youtube::RuntimeAvailable()));
  } else if (method == "create" && args != nullptr) {
    std::shared_ptr<flutter::MethodResult<EncodableValue>> pending(
        std::move(result));
    slimm_youtube::Create(g_view, Text(*args, "html"), SendMessageToDart,
                          [pending](bool created) {
                            pending->Success(EncodableValue(created));
                          });
  } else if (method == "setBounds" && args != nullptr) {
    slimm_youtube::SetBounds(Physical(*args));
    result->Success();
  } else if (method == "setVisible" && args != nullptr) {
    const EncodableValue* visible = Field(*args, "visible");
    const bool* flag = visible == nullptr ? nullptr : std::get_if<bool>(visible);
    slimm_youtube::SetVisible(flag != nullptr && *flag);
    result->Success();
  } else if (method == "run" && args != nullptr) {
    slimm_youtube::Run(Text(*args, "script"));
    result->Success();
  } else if (method == "destroy") {
    slimm_youtube::Destroy();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterYoutubePlayerChannel(flutter::BinaryMessenger* messenger,
                                  HWND view) {
  g_view = view;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "top.npcserver.slimm/youtube_player",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(Handle);
}

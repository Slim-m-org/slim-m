#include "windows_toasts_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "toast_history_win.h"

namespace {

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

const std::string* StringArgument(const flutter::EncodableMap& map,
                                  const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  if (found == map.end()) return nullptr;
  return std::get_if<std::string>(&found->second);
}

}  // namespace

void RegisterWindowsToastsChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "slimm/windows_toasts",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [channel](const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                    result) {
        if (call.method_name() != "remove") {
          result->NotImplemented();
          return;
        }
        const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
        const std::string* tag = map ? StringArgument(*map, "tag") : nullptr;
        const std::string* aumid = map ? StringArgument(*map, "aumid") : nullptr;
        if (!tag || !aumid) {
          result->Error("bad_arguments", "remove takes a tag and an aumid");
          return;
        }
        const bool removed = RemoveToast(Wide(*tag), Wide(*aumid));
        result->Success(flutter::EncodableValue(removed));
      });
}

// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <memory>
#include <string>
#include <variant>

#include "youtube_player_win.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
flutter::TextureRegistrar* g_textures = nullptr;
IDXGIAdapter* g_adapter = nullptr;
HWND g_view = nullptr;
std::unique_ptr<flutter::TextureVariant> g_texture;
std::atomic<int64_t> g_texture_id{-1};
FlutterDesktopGpuSurfaceDescriptor g_descriptor = {};

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

// Flutter asks on its raster thread; the frame is copied into this one shared texture, so its handle stays valid.
const FlutterDesktopGpuSurfaceDescriptor* Descriptor(size_t, size_t) {
  slimm_youtube::SharedFrame frame = slimm_youtube::Latest();
  if (frame.handle == nullptr) return nullptr;
  g_descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  g_descriptor.handle = frame.handle;
  g_descriptor.width = g_descriptor.visible_width = frame.width;
  g_descriptor.height = g_descriptor.visible_height = frame.height;
  g_descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
  g_descriptor.release_callback = nullptr;
  g_descriptor.release_context = nullptr;
  return &g_descriptor;
}

void OnFrame() {
  int64_t id = g_texture_id.load();
  if (id >= 0 && g_textures != nullptr) g_textures->MarkTextureFrameAvailable(id);
}

void DropTexture() {
  int64_t id = g_texture_id.exchange(-1);
  if (id >= 0 && g_textures != nullptr) g_textures->UnregisterTexture(id, nullptr);
}

bool ParsePointerKind(const std::string& name, slimm_youtube::PointerKind* out) {
  using slimm_youtube::PointerKind;
  if (name == "enter") {
    *out = PointerKind::kEnter;
  } else if (name == "move") {
    *out = PointerKind::kMove;
  } else if (name == "down") {
    *out = PointerKind::kDown;
  } else if (name == "up") {
    *out = PointerKind::kUp;
  } else if (name == "leave") {
    *out = PointerKind::kLeave;
  } else {
    return false;
  }
  return true;
}

void Create(const EncodableMap& args,
            std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  DropTexture();
  if (g_textures == nullptr) {
    result->Success(EncodableValue(int64_t{-1}));
    return;
  }
  std::shared_ptr<flutter::MethodResult<EncodableValue>> pending(
      std::move(result));
  slimm_youtube::Create(
      g_view, g_adapter, Text(args, "html"), SendMessageToDart, OnFrame,
      [pending](bool created) {
        if (!created) {
          pending->Success(EncodableValue(int64_t{-1}));
          return;
        }
        g_texture = std::make_unique<flutter::TextureVariant>(
            flutter::GpuSurfaceTexture(
                kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, Descriptor));
        g_texture_id = g_textures->RegisterTexture(g_texture.get());
        pending->Success(EncodableValue(g_texture_id.load()));
      });
}

void Handle(const flutter::MethodCall<EncodableValue>& call,
            std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableMap* args = std::get_if<EncodableMap>(call.arguments());
  if (method == "probe") {
    result->Success(EncodableValue(slimm_youtube::RuntimeAvailable()));
  } else if (method == "create" && args != nullptr) {
    Create(*args, std::move(result));
  } else if (method == "resize" && args != nullptr) {
    slimm_youtube::Resize(Number(*args, "width"), Number(*args, "height"),
                          Number(*args, "pixelRatio"));
    result->Success();
  } else if (method == "pointer" && args != nullptr) {
    slimm_youtube::PointerKind kind;
    if (ParsePointerKind(Text(*args, "kind"), &kind)) {
      slimm_youtube::Pointer(kind, Number(*args, "x"), Number(*args, "y"));
    }
    result->Success();
  } else if (method == "run" && args != nullptr) {
    slimm_youtube::Run(Text(*args, "script"));
    result->Success();
  } else if (method == "destroy") {
    DropTexture();
    slimm_youtube::Destroy();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterYoutubePlayerChannel(flutter::FlutterEngine* engine, HWND view) {
  g_view = view;
  // Frames must be copied on the GPU Flutter draws with, or the shared handle cannot open.
  engine->GetGraphicsAdapter(&g_adapter);
  g_textures = flutter::PluginRegistrarManager::GetInstance()
                   ->GetRegistrar<flutter::PluginRegistrarWindows>(
                       engine->GetRegistrarForPlugin("YoutubePlayer"))
                   ->texture_registrar();
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      engine->messenger(), "top.npcserver.slimm/youtube_player",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(Handle);
}

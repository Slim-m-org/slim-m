// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "youtube_player_texture.h"

#include <cstdint>
#include <cstring>
#include <mutex>
#include <utility>
#include <vector>

namespace {

struct Frame {
  std::vector<uint32_t> pixels;
  uint32_t width = 0;
  uint32_t height = 0;
};

// Cairo's ARGB32 is a native-endian 0xAARRGGBB word; Flutter reads bytes R, G, B, A.
inline uint32_t ToRgba(uint32_t argb) {
  return (argb & 0xFF00FF00u) | ((argb >> 16) & 0xFFu) |
         ((argb & 0xFFu) << 16);
}

}  // namespace

/// Three frames so neither thread waits on the other's copy: [back] is
/// written on the main thread, [front] read on the raster thread, and the
/// lock only guards the swap through [ready].
struct _SlimmVideoTexture {
  FlPixelBufferTexture parent_instance;
  std::mutex* lock;
  Frame* back;
  Frame* ready;
  Frame* front;
  bool fresh;
};

G_DEFINE_TYPE(SlimmVideoTexture, slimm_video_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean slimm_video_texture_copy_pixels(FlPixelBufferTexture* texture,
                                                const uint8_t** buffer,
                                                uint32_t* width,
                                                uint32_t* height,
                                                GError** error) {
  SlimmVideoTexture* self = SLIMM_VIDEO_TEXTURE(texture);
  {
    std::lock_guard<std::mutex> guard(*self->lock);
    if (self->fresh) {
      std::swap(self->ready, self->front);
      self->fresh = false;
    }
  }
  Frame* frame = self->front;
  if (frame->width == 0) {
    // Nothing captured yet: one black pixel, which the Texture widget stretches.
    frame->pixels.assign(1, 0xFF000000u);
    frame->width = 1;
    frame->height = 1;
  }
  *buffer = reinterpret_cast<const uint8_t*>(frame->pixels.data());
  *width = frame->width;
  *height = frame->height;
  return TRUE;
}

static void slimm_video_texture_finalize(GObject* object) {
  SlimmVideoTexture* self = SLIMM_VIDEO_TEXTURE(object);
  delete self->back;
  delete self->ready;
  delete self->front;
  delete self->lock;
  G_OBJECT_CLASS(slimm_video_texture_parent_class)->finalize(object);
}

static void slimm_video_texture_class_init(SlimmVideoTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      slimm_video_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = slimm_video_texture_finalize;
}

static void slimm_video_texture_init(SlimmVideoTexture* self) {
  self->lock = new std::mutex();
  self->back = new Frame();
  self->ready = new Frame();
  self->front = new Frame();
  self->fresh = false;
}

SlimmVideoTexture* slimm_video_texture_new() {
  return SLIMM_VIDEO_TEXTURE(
      g_object_new(slimm_video_texture_get_type(), nullptr));
}

void slimm_video_texture_store(SlimmVideoTexture* self,
                               cairo_surface_t* image) {
  const int width = cairo_image_surface_get_width(image);
  const int height = cairo_image_surface_get_height(image);
  const int stride = cairo_image_surface_get_stride(image);
  const unsigned char* data = cairo_image_surface_get_data(image);
  if (data == nullptr || width <= 0 || height <= 0) return;
  Frame* frame = self->back;
  frame->pixels.resize(static_cast<size_t>(width) * height);
  frame->width = width;
  frame->height = height;
  uint32_t* out = frame->pixels.data();
  for (int y = 0; y < height; y++) {
    const uint32_t* row = reinterpret_cast<const uint32_t*>(data + y * stride);
    for (int x = 0; x < width; x++) *out++ = ToRgba(row[x]);
  }
  std::lock_guard<std::mutex> guard(*self->lock);
  std::swap(self->back, self->ready);
  self->fresh = true;
}

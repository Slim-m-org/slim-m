// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#include "screen_overlay_png.h"

#include <cstring>

namespace slimm_overlay {
namespace {

struct PngSource {
  const std::vector<uint8_t>* bytes;
  size_t offset;
};

cairo_status_t ReadPng(void* closure, unsigned char* data, unsigned int length) {
  PngSource* source = static_cast<PngSource*>(closure);
  if (source->offset + length > source->bytes->size()) {
    return CAIRO_STATUS_READ_ERROR;
  }
  memcpy(data, source->bytes->data() + source->offset, length);
  source->offset += length;
  return CAIRO_STATUS_SUCCESS;
}

}  // namespace

cairo_surface_t* DecodePng(const std::vector<uint8_t>& png) {
  if (png.empty()) return nullptr;
  PngSource source = {&png, 0};
  cairo_surface_t* decoded =
      cairo_image_surface_create_from_png_stream(ReadPng, &source);
  if (cairo_surface_status(decoded) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(decoded);
    return nullptr;
  }
  return decoded;
}

}  // namespace slimm_overlay

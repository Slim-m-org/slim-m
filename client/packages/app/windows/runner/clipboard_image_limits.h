// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_CLIPBOARD_IMAGE_LIMITS_H_
#define RUNNER_CLIPBOARD_IMAGE_LIMITS_H_

#include <cstdint>

namespace slimm {

/// The server's MAX_IMAGE_PIXELS: a decode past it is refused before any pixel
/// is allocated.
constexpr uint64_t kMaxClipboardImagePixels = 40000000;

inline bool ClipboardImageTooLarge(uint32_t width, uint32_t height) {
  return width == 0 || height == 0 ||
         static_cast<uint64_t>(width) * height > kMaxClipboardImagePixels;
}

}  // namespace slimm

#endif  // RUNNER_CLIPBOARD_IMAGE_LIMITS_H_

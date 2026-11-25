// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#ifndef RUNNER_CLIPBOARD_IMAGE_LIMITS_H_
#define RUNNER_CLIPBOARD_IMAGE_LIMITS_H_

namespace slimm_clipboard {

// The same side the Dart paste path refuses (maxClipboardImageSide).
constexpr int kMaxImageSide = 8192;

inline bool ImageTooLarge(int width, int height) {
  return width <= 0 || height <= 0 || width > kMaxImageSide ||
         height > kMaxImageSide;
}

// Reads the canvas size from a PNG's IHDR chunk without decoding it.
inline bool PngDimensions(const unsigned char* data, unsigned long size,
                          int* width, int* height) {
  static const unsigned char kSignature[8] = {0x89, 'P', 'N', 'G',
                                              0x0D, 0x0A, 0x1A, 0x0A};
  if (size < 24) return false;
  for (int i = 0; i < 8; ++i) {
    if (data[i] != kSignature[i]) return false;
  }
  const bool is_header = data[12] == 'I' && data[13] == 'H' &&
                         data[14] == 'D' && data[15] == 'R';
  if (!is_header) return false;
  auto read32 = [data](int at) {
    return (static_cast<unsigned long>(data[at]) << 24) |
           (static_cast<unsigned long>(data[at + 1]) << 16) |
           (static_cast<unsigned long>(data[at + 2]) << 8) | data[at + 3];
  };
  const unsigned long w = read32(16);
  const unsigned long h = read32(20);
  if (w > 0x7FFFFFFF || h > 0x7FFFFFFF) return false;
  *width = static_cast<int>(w);
  *height = static_cast<int>(h);
  return true;
}

}  // namespace slimm_clipboard

#endif  // RUNNER_CLIPBOARD_IMAGE_LIMITS_H_

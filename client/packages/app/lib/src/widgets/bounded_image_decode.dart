// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decoding an image whose size the sender chose, without trusting it.
///
/// A small encoded payload can declare any pixel size, and a plain decode
/// allocates the full bitmap before anything can look at it. This reads the
/// declared size first, refuses what is past a ceiling, and decodes the rest
/// no larger than the caller will ever draw.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// The declared size of an image was past the ceiling the caller allows.
class ImageTooLargeException implements Exception {
  const ImageTooLargeException(this.width, this.height);

  final int width;
  final int height;

  @override
  String toString() => 'ImageTooLargeException: ${width}x$height';
}

/// Decodes [bytes] to a bitmap whose longer side is at most [maxSide],
/// keeping the aspect ratio and never scaling up.
///
/// Throws [ImageTooLargeException] before any pixel is allocated when the
/// declared size exceeds [maxSourcePixels]; with no ceiling, only the
/// retained bitmap is bounded, not the transient decode. The caller owns the
/// returned image and must dispose it.
Future<ui.Image> decodeBoundedImage(
  Uint8List bytes, {
  required int maxSide,
  int? maxSourcePixels,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final width = descriptor.width;
    final height = descriptor.height;
    if (maxSourcePixels != null && width * height > maxSourcePixels) {
      throw ImageTooLargeException(width, height);
    }
    final shrink = math.max(width, height) > maxSide;
    codec = await descriptor.instantiateCodec(
      targetWidth: shrink && width >= height ? maxSide : null,
      targetHeight: shrink && height > width ? maxSide : null,
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

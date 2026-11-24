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

import 'package:flutter/foundation.dart'
    show immutable, kIsWeb, visibleForTesting;
import 'package:flutter/painting.dart';

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
  if (kIsWeb) {
    return decodeBoundedViaPostDecodeCheck(bytes, maxSide, maxSourcePixels);
  }
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

/// The web engine cannot read a descriptor's size, so the size is checked
/// after the browser's own decode and an oversized result is redrawn smaller.
@visibleForTesting
Future<ui.Image> decodeBoundedViaPostDecodeCheck(
  Uint8List bytes,
  int maxSide,
  int? maxSourcePixels,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  final width = image.width;
  final height = image.height;
  if (maxSourcePixels != null && width * height > maxSourcePixels) {
    image.dispose();
    throw ImageTooLargeException(width, height);
  }
  final longest = math.max(width, height);
  if (longest <= maxSide) return image;
  final scale = maxSide / longest;
  final targetW = math.max(1, (width * scale).round());
  final targetH = math.max(1, (height * scale).round());
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Rect.fromLTWH(0, 0, targetW.toDouble(), targetH.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(targetW, targetH);
  } finally {
    picture.dispose();
    image.dispose();
  }
}

/// The most pixels a sender-chosen picture may declare before it is refused.
///
/// This is the server's own upload ceiling, and it holds for PNG and the other
/// formats the engine can only decode at full size: 40 MP is a 160 MB bitmap.
const int kMaxDeclaredPixels = 40 * 1000 * 1000;

/// Animated GIFs hold a decoded frame at a time but cost far more to scrub.
const int kMaxDeclaredGifPixels = 16 * 1000 * 1000;

/// JPEG and WebP are downsampled while decoding, so a camera original that the
/// server accepts (up to 160 MP) stays cheap at screen size.
const int kMaxDeclaredScaledDecodePixels = 200 * 1000 * 1000;

/// The declared-pixel ceiling that fits the format [bytes] starts as.
int declaredPixelCeiling(Uint8List bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0xFF, 0xD8, 0xFF]) ||
      (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
          startsWith(const [0x57, 0x45, 0x42, 0x50], 8))) {
    return kMaxDeclaredScaledDecodePixels;
  }
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) {
    return kMaxDeclaredGifPixels;
  }
  return kMaxDeclaredPixels;
}

/// Throws [ImageTooLargeException] when [buffer] declares more than
/// [maxPixels], before any pixel is allocated. The web engine cannot read a
/// declared size, so there the check is skipped.
Future<void> checkDeclaredSize(
  ui.ImmutableBuffer buffer, {
  int maxPixels = kMaxDeclaredPixels,
}) async {
  if (kIsWeb) return;
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final width = descriptor.width;
  final height = descriptor.height;
  descriptor.dispose();
  if (width * height > maxPixels) throw ImageTooLargeException(width, height);
}

/// A [MemoryImage] that refuses a picture declaring more pixels than its
/// format allows ([declaredPixelCeiling]), so it fails like any undecodable image does.
@immutable
class BoundedMemoryImage extends MemoryImage {
  const BoundedMemoryImage(super.bytes);

  @override
  ImageStreamCompleter loadImage(
    MemoryImage key,
    ImageDecoderCallback decode,
  ) => super.loadImage(key, (buffer, {getTargetSize}) async {
    try {
      await checkDeclaredSize(
        buffer,
        maxPixels: declaredPixelCeiling(key.bytes),
      );
    } catch (_) {
      buffer.dispose();
      rethrow;
    }
    return decode(buffer, getTargetSize: getTargetSize);
  });
}
